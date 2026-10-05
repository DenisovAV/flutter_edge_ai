// LitertlmManifestResolver against the HuggingFaceResolver seam (#454/#461):
// selection is by declared ModelFileType only, the manifest's shapes map onto
// ResolvedHfModel/ModelRuntimeDefaults per the shipped-data field shapes
// (recommended is an optional ARRAY, capabilities.thinking is an OBJECT,
// context_length sits on model, session_defaults is an open object), and the
// URL the resolver hands back is authoritative: revision-pinned and encoded
// per path segment.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_gemma/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_gemma_litertlm/src/manifest/litertlm_manifest.dart';
import 'package:flutter_gemma_litertlm/src/manifest/litertlm_manifest_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// The LFM2.5 fixture — the shipped manifest whose shape (a cpu-only int4, a
/// cpu+gpu re-export, a cpu-only int8, with conflicting per-platform
/// recommendations) discriminates every branch of the spec's resolution rule.
String lfmFixture() => File(
  'test/manifest/fixtures/litert-community__LFM2.5-1.2B-Instruct.json',
).readAsStringSync();

/// A resolver whose fetch returns [body] and records what was requested.
class _Fetches {
  Uri? url;
  Map<String, String>? headers;

  LitertlmManifestResolver resolver(Object body, {String revision = 'main'}) =>
      LitertlmManifestResolver(
        revision: revision,
        fetch: (u, h) async {
          url = u;
          headers = h;
          if (body is ManifestFetchException) throw body;
          return body is String ? body : jsonEncode(body);
        },
      );
}

/// Minimal valid manifest; override pieces per test.
Map<String, dynamic> manifest({
  Map<String, dynamic>? model,
  List<Map<String, dynamic>>? variants,
}) => {
  'manifest_schema': '0.1.0',
  'repo': 'org/name',
  'generated': '2026-08-27',
  'model': model ?? {'display_name': 'Name'},
  'variants':
      variants ??
      [
        {
          'file': 'model.litertlm',
          'sha256': 'a' * 64,
          'size_bytes': 123456,
          'quantization': 'int8',
          'backends': ['cpu'],
          'default_backend': 'cpu',
        },
      ],
};

void main() {
  group('canResolve claims exactly ModelFileType.litertlm', () {
    const r = LitertlmManifestResolver();
    test('accepts a declared litertlm hint', () {
      expect(r.canResolve('org/name', fileType: ModelFileType.litertlm), true);
    });
    test('declines a null hint (no routing by registration order)', () {
      expect(r.canResolve('org/name'), false);
    });
    test('declines every other file type', () {
      for (final t in ModelFileType.values) {
        if (t == ModelFileType.litertlm) continue;
        expect(r.canResolve('org/name', fileType: t), false, reason: '$t');
      }
    });
  });

  group('registry selection', () {
    setUp(() => HuggingFaceResolverRegistry.instance.reset());
    tearDown(() => HuggingFaceResolverRegistry.instance.reset());

    test('found for litertlm, not for a bare or foreign hint', () {
      const r = LitertlmManifestResolver();
      HuggingFaceResolverRegistry.instance.registerAll([r]);
      expect(
        HuggingFaceResolverRegistry.instance.findFor(
          'org/name',
          fileType: ModelFileType.litertlm,
        ),
        same(r),
      );
      expect(HuggingFaceResolverRegistry.instance.findFor('org/name'), isNull);
      expect(
        HuggingFaceResolverRegistry.instance.findFor(
          'org/name',
          fileType: ModelFileType.onnx,
        ),
        isNull,
      );
    });
  });

  group('manifest → ResolvedHfModel mapping', () {
    final full = manifest(
      model: {
        'display_name': 'Qwen3-4B-Thinking-2507',
        'base_model': 'Qwen/Qwen3-4B-Thinking-2507',
        'architecture': 'qwen3-dense (36 layers)',
        'context_length': 4096,
        'session_defaults': {
          'max_output_tokens_min': 2048,
          'notes': 'Reasoning model: needs the output floor.',
        },
        'capabilities': {
          'vision': false,
          'audio': false,
          'thinking': {
            'declared': true,
            'channel': {'start': '<think>\n', 'end': '\n</think>'},
          },
        },
      },
      variants: [
        {
          'file': 'model.litertlm',
          'sha256': 'b' * 64,
          'size_bytes': 999,
          'quantization': 'int4',
          'backends': ['cpu', 'gpu'],
          'default_backend': 'gpu',
          'recommended': [
            {'platform': 'ios', 'backend': 'gpu', 'reason': 'fastest verified'},
          ],
          'requirements': {
            'platform_notes': ['budget RAM accordingly'],
          },
          'known_issues': ['a known issue'],
        },
      ],
    );

    test('runtime defaults come from the documented field homes', () async {
      final f = _Fetches();
      final r = await f.resolver(full).resolve('org/name', platform: 'ios');
      // context_length lives on model, not the variant.
      expect(r.runtime.maxTokens, 4096);
      // capabilities.thinking is an object; `declared` is what maps here.
      expect(r.runtime.isThinking, true);
      // session_defaults.max_output_tokens_min → the minOutputTokens FLOOR.
      expect(r.runtime.minOutputTokens, 2048);
      expect(r.runtime.supportImage, false);
      expect(r.runtime.supportAudio, false);
      expect(r.runtime.preferredBackend, PreferredBackend.gpu);
      expect(r.fileType, ModelFileType.litertlm);
      expect(r.modelType, ModelType.qwen3);
      expect(r.file, 'model.litertlm');
      expect(
        r.url,
        'https://huggingface.co/org/name/resolve/main/model.litertlm',
      );
      expect(r.sha256, 'b' * 64);
      expect(r.sizeBytes, 999);
    });

    test('notes carry platform notes, known issues, and the session-defaults '
        'notes string, and are unmodifiable', () async {
      final f = _Fetches();
      final r = await f.resolver(full).resolve('org/name', platform: 'ios');
      expect(r.notes, [
        'budget RAM accordingly',
        'a known issue',
        'Reasoning model: needs the output floor.',
      ]);
      expect(() => r.notes.add('x'), throwsUnsupportedError);
    });

    test('no recommended rows → default_backend (the shape 21 of the 35 '
        'published variants have)', () async {
      final f = _Fetches();
      final r = await f
          .resolver(manifest())
          .resolve('org/name', platform: 'android');
      expect(r.file, 'model.litertlm');
      expect(r.runtime.preferredBackend, PreferredBackend.cpu);
    });

    test(
      'a caller backend hint is honoured when the variant lists it',
      () async {
        final m = manifest(
          variants: [
            {
              'file': 'model.litertlm',
              'sha256': 'a' * 64,
              'size_bytes': 1,
              'quantization': 'int8',
              'backends': ['cpu', 'gpu'],
              'default_backend': 'cpu',
            },
          ],
        );
        final f = _Fetches();
        final r = await f
            .resolver(m)
            .resolve('org/name', preferredBackend: PreferredBackend.gpu);
        expect(r.runtime.preferredBackend, PreferredBackend.gpu);
        // Honoured, so nothing to report.
        expect(r.notes, isEmpty);
      },
    );

    test(
      'an explicit backend hint is a filter: android+gpu picks the gpu '
      're-export over the cpu recommendation (spec resolution rule)',
      () async {
        final f = _Fetches();
        final r = await f
            .resolver(lfmFixture())
            .resolve(
              'litert-community/LFM2.5-1.2B-Instruct',
              platform: 'android',
              preferredBackend: PreferredBackend.gpu,
            );
        expect(r.file, 'LFM2.5-1.2B-Instruct_int4_gpu.litertlm');
        expect(r.runtime.preferredBackend, PreferredBackend.gpu);
      },
    );

    test('with a backend hint, only recommendations naming it count: '
        'macos+cpu picks the int8 cpu recommendation, not the gpu '
        're-export forced onto cpu', () async {
      final f = _Fetches();
      final r = await f
          .resolver(lfmFixture())
          .resolve(
            'litert-community/LFM2.5-1.2B-Instruct',
            platform: 'macos',
            preferredBackend: PreferredBackend.cpu,
          );
      expect(r.file, 'LFM2.5-1.2B-Instruct_int8.litertlm');
      expect(r.runtime.preferredBackend, PreferredBackend.cpu);
    });

    test(
      'a hint no variant is verified on is dropped, never silently '
      'claimed: npu resolves to the platform pick with its own backend',
      () async {
        final f = _Fetches();
        // macos discriminates: the platform pick (int4_gpu via the macos
        // recommendation) differs from the no-platform fallback (int4/cpu),
        // so this also pins that the drop lane keeps the platform.
        final r = await f
            .resolver(lfmFixture())
            .resolve(
              'litert-community/LFM2.5-1.2B-Instruct',
              platform: 'macos',
              preferredBackend: PreferredBackend.npu,
            );
        expect(r.file, 'LFM2.5-1.2B-Instruct_int4_gpu.litertlm');
        expect(r.runtime.preferredBackend, PreferredBackend.gpu);
        // The downgrade is on the record for release builds too (gemmaLog is
        // debug-only): last note, naming the dropped hint and the outcome.
        expect(
          r.notes.last,
          allOf(
            contains('litert-community/LFM2.5-1.2B-Instruct'),
            contains('requested npu'),
            contains('(gpu)'),
          ),
        );
        // ...and only there: the variant's own notes come first, untouched.
        final noHint = await f
            .resolver(lfmFixture())
            .resolve(
              'litert-community/LFM2.5-1.2B-Instruct',
              platform: 'macos',
            );
        expect(r.notes.sublist(0, r.notes.length - 1), noHint.notes);
      },
    );

    test('gpu hint on a cpu-only repo falls back to the manifest choice '
        '(the hint is dropped, not substituted into the result)', () async {
      final f = _Fetches();
      final r = await f
          .resolver(manifest())
          .resolve('org/name', preferredBackend: PreferredBackend.gpu);
      expect(r.file, 'model.litertlm');
      expect(r.runtime.preferredBackend, PreferredBackend.cpu);
      expect(r.notes, [
        'No variant of "org/name" is verified on the requested gpu backend; '
            'resolved without that hint (cpu).',
      ]);
    });

    test(
      'the "unknown" platform key from core means "no per-platform hint"',
      () async {
        final m = manifest(
          variants: [
            {
              'file': 'model.litertlm',
              'sha256': 'a' * 64,
              'size_bytes': 1,
              'quantization': 'int8',
              'backends': ['cpu', 'gpu'],
              'default_backend': 'gpu',
              'recommended': [
                {'platform': 'android', 'backend': 'cpu'},
              ],
            },
          ],
        );
        final f = _Fetches();
        final r = await f.resolver(m).resolve('org/name', platform: 'unknown');
        // Falls through to default_backend, exactly like passing no platform.
        expect(r.runtime.preferredBackend, PreferredBackend.gpu);
      },
    );

    test(
      'silent manifest → null runtime fields (SDK defaults apply)',
      () async {
        final f = _Fetches();
        final r = await f.resolver(manifest()).resolve('org/name');
        expect(r.runtime.maxTokens, isNull);
        expect(r.runtime.minOutputTokens, isNull);
        expect(r.modelType, isNull);
        // No `capabilities` block at all: the manifest never looked, which
        // is "silent" (null) — not "declared unsupported" (false).
        expect(r.runtime.supportImage, isNull);
        expect(r.runtime.supportAudio, isNull);
        expect(r.runtime.isThinking, isNull);
      },
    );

    test('a present capabilities block is a declaration: keys it omits are '
        'false, not null', () async {
      final f = _Fetches();
      final r = await f
          .resolver(
            manifest(
              model: {
                'display_name': 'V',
                'capabilities': {'vision': true},
              },
            ),
          )
          .resolve('org/name');
      expect(r.runtime.supportImage, true);
      expect(r.runtime.supportAudio, false);
      expect(r.runtime.isThinking, false);
    });

    test(
      'session_defaults is an open object: a notes-only object gives no '
      'minOutputTokens; a value outside `integer, minimum: 1` is ignored',
      () async {
        final f = _Fetches();
        final notesOnly = await f
            .resolver(
              manifest(
                model: {
                  'display_name': 'N',
                  'session_defaults': {'notes': 'only notes'},
                },
              ),
            )
            .resolve('org/name');
        expect(notesOnly.runtime.minOutputTokens, isNull);
        expect(notesOnly.notes, ['only notes']);

        for (final bad in ['2048', 2048.0, 0, -1, true]) {
          final junk = await f
              .resolver(
                manifest(
                  model: {
                    'display_name': 'N',
                    'session_defaults': {'max_output_tokens_min': bad},
                  },
                ),
              )
              .resolve('org/name');
          expect(junk.runtime.minOutputTokens, isNull, reason: '$bad');
        }
        final one = await f
            .resolver(
              manifest(
                model: {
                  'display_name': 'N',
                  'session_defaults': {'max_output_tokens_min': 1},
                },
              ),
            )
            .resolve('org/name');
        expect(one.runtime.minOutputTokens, 1);
      },
    );

    test('a backend name outside the PreferredBackend enum maps to null '
        '(SDK default), not an error', () async {
      final m = manifest(
        variants: [
          {
            'file': 'model.litertlm',
            'sha256': 'a' * 64,
            'size_bytes': 1,
            'quantization': 'int8',
            'backends': ['webgpu'],
            'default_backend': 'webgpu',
          },
        ],
      );
      final f = _Fetches();
      final r = await f.resolver(m).resolve('org/name');
      expect(r.runtime.preferredBackend, isNull);
      expect(r.file, 'model.litertlm');
    });
  });

  group('fetch: URL, revision, auth', () {
    test('fetches the manifest at /resolve/main/ with no auth header by '
        'default', () async {
      final f = _Fetches();
      await f.resolver(manifest()).resolve('org/name');
      expect(
        f.url.toString(),
        'https://huggingface.co/org/name/resolve/main/litertlm_manifest.json',
      );
      expect(f.headers, isEmpty);
    });

    test('a token becomes a Bearer header', () async {
      final f = _Fetches();
      await f.resolver(manifest()).resolve('org/name', token: 'hf_secret');
      expect(f.headers, {'Authorization': 'Bearer hf_secret'});
    });

    test('a pinned revision reaches both the manifest GET and the returned '
        'url', () async {
      final f = _Fetches();
      final r = await f
          .resolver(manifest(), revision: 'abc123')
          .resolve('org/name');
      expect(f.url!.path, '/org/name/resolve/abc123/litertlm_manifest.json');
      expect(
        r.url,
        'https://huggingface.co/org/name/resolve/abc123/model.litertlm',
      );
    });

    test('a slash-bearing revision is one encoded path segment in both '
        'URLs', () async {
      final f = _Fetches();
      final r = await f
          .resolver(manifest(), revision: 'refs/pr/1')
          .resolve('org/name');
      expect(
        f.url.toString(),
        'https://huggingface.co/org/name/resolve/refs%2Fpr%2F1/'
        'litertlm_manifest.json',
      );
      expect(
        r.url,
        'https://huggingface.co/org/name/resolve/refs%2Fpr%2F1/'
        'model.litertlm',
      );
    });

    test('a nested variant path keeps its structure (per-segment encoding, '
        'same rule as fromHuggingFace)', () async {
      final m = manifest(
        variants: [
          {
            'file': 'int4/model v2.litertlm',
            'sha256': 'a' * 64,
            'size_bytes': 1,
            'quantization': 'int4',
            'backends': ['cpu'],
            'default_backend': 'cpu',
          },
        ],
      );
      final f = _Fetches();
      final r = await f.resolver(m).resolve('org/name');
      expect(
        r.url,
        'https://huggingface.co/org/name/resolve/main/int4/model%20v2.litertlm',
      );
    });

    test('an empty repo fails loud at the seam', () {
      final f = _Fetches();
      expect(() => f.resolver(manifest()).resolve('  '), throwsArgumentError);
    });
  });

  group('failure modes', () {
    test(
      '404 names the missing manifest and the fromHuggingFace fallback',
      () async {
        final f = _Fetches();
        final r = f.resolver(
          ManifestFetchException(
            Uri.parse('https://huggingface.co/x'),
            'GET failed with HTTP 404',
            statusCode: 404,
          ),
        );
        await expectLater(
          r.resolve('org/name'),
          throwsA(
            isA<ManifestFetchException>()
                .having((e) => e.statusCode, 'statusCode', 404)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('does not ship a litertlm_manifest.json'),
                    contains('fromHuggingFace'),
                  ),
                ),
          ),
        );
      },
    );

    test('401 explains gated/private/nonexistent (measured HF behaviour: '
        'repo existence is not revealed unauthenticated)', () async {
      final f = _Fetches();
      final r = f.resolver(
        ManifestFetchException(
          Uri.parse('https://huggingface.co/x'),
          'GET failed with HTTP 401',
          statusCode: 401,
        ),
      );
      await expectLater(
        r.resolve('org/name'),
        throwsA(
          isA<ManifestFetchException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('gated'), contains('token')),
              ),
        ),
      );
    });

    test('403 points at token acceptance for gated repos', () async {
      final f = _Fetches();
      final r = f.resolver(
        ManifestFetchException(
          Uri.parse('https://huggingface.co/x'),
          'GET failed with HTTP 403',
          statusCode: 403,
        ),
      );
      await expectLater(
        r.resolve('org/name'),
        throwsA(
          isA<ManifestFetchException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', contains('license')),
        ),
      );
    });

    test('other HTTP failures pass through unrewritten', () async {
      final f = _Fetches();
      final r = f.resolver(
        ManifestFetchException(
          Uri.parse('https://huggingface.co/x'),
          'GET failed with HTTP 503',
          statusCode: 503,
        ),
      );
      await expectLater(
        r.resolve('org/name'),
        throwsA(
          isA<ManifestFetchException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });

    test('a body that is not JSON is a FormatException', () async {
      final f = _Fetches();
      await expectLater(
        f.resolver('<!doctype html>').resolve('org/name'),
        throwsFormatException,
      );
    });

    test('a 0.2 manifest is refused, not half-parsed', () async {
      final f = _Fetches();
      final m = manifest()..['manifest_schema'] = '0.2.0';
      await expectLater(
        f.resolver(m).resolve('org/name'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('0.1.x'),
          ),
        ),
      );
    });

    test('a variant with no backends is refused at parse '
        '(schema requires minItems: 1)', () async {
      final f = _Fetches();
      for (final variant in [
        {'file': 'a.litertlm', 'quantization': 'q', 'backends': <String>[]},
        {'file': 'a.litertlm', 'quantization': 'q'},
      ]) {
        await expectLater(
          f.resolver(manifest(variants: [variant])).resolve('org/name'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('minItems'),
            ),
          ),
        );
      }
    });

    test('a malformed field is surfaced as a FormatException naming the '
        'repo, not an opaque cast error', () async {
      final f = _Fetches();
      final m = manifest(
        variants: [
          {
            'file': 42, // wrong type
            'quantization': 'int8',
          },
        ],
      );
      await expectLater(
        f.resolver(m).resolve('org/name'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('org/name'),
          ),
        ),
      );
    });

    /// A manifest with one element of a string list replaced by a number.
    Map<String, dynamic> withBadElement(String list) {
      final variant = <String, dynamic>{
        'file': 'model.litertlm',
        'quantization': 'int8',
        'backends': ['cpu'],
        'requirements': {
          'platform_notes': ['ok'],
        },
        'known_issues': ['ok'],
      };
      switch (list) {
        case 'platform_notes':
          variant['requirements'] = {
            'platform_notes': ['ok', 42],
          };
        case 'known_issues':
          variant['known_issues'] = ['ok', 42];
        case 'backends':
          variant['backends'] = ['cpu', 42];
      }
      return manifest(variants: [variant]);
    }

    test('a wrong-typed element in platform_notes / known_issues / backends '
        'is a FormatException at resolve, not a TypeError from a lazy cast '
        'later', () async {
      final f = _Fetches();
      for (final list in ['platform_notes', 'known_issues', 'backends']) {
        await expectLater(
          f.resolver(withBadElement(list)).resolve('org/name'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('org/name'),
            ),
          ),
          reason: list,
        );
        // The vendored reader itself checks the elements at parse.
        expect(
          () => LitertlmManifest.fromJson(withBadElement(list)),
          throwsA(isA<TypeError>()),
          reason: list,
        );
      }
    });

    test('a wrong-typed base_model / architecture is a FormatException, '
        'not a TypeError from the modelType mapping', () async {
      final f = _Fetches();
      for (final field in ['base_model', 'architecture']) {
        final m = manifest(model: {'display_name': 'N', field: 3});
        await expectLater(
          f.resolver(m).resolve('org/name'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('org/name'),
            ),
          ),
          reason: field,
        );
      }
    });
  });

  group('modelType mapping (conservative: null over a wrong guess)', () {
    ModelType? map(String base, {String display = '', String arch = ''}) =>
        LitertlmManifestResolver.mapModelType(
          baseModel: base,
          displayName: display,
          architecture: arch,
        );

    test('deepseek wins over the qwen in a distill id', () {
      expect(
        map(
          'deepseek-ai/DeepSeek-R1-Distill-Qwen-7B',
          arch: 'Qwen2 dense decoder (Qwen2ForCausalLM, 28 layers)',
        ),
        ModelType.deepSeek,
      );
    });

    test('qwen3.5 is qwen (ChatML without the qwen3 /no_think injection)', () {
      expect(map('Qwen/Qwen3.5-4B'), ModelType.qwen);
      expect(map('Qwen/Qwen3.5-0.8B'), ModelType.qwen);
    });

    test('qwen3 by id, and by the Qwen3ForCausalLM class token when the id '
        'hides the family (a finetune)', () {
      expect(map('Qwen/Qwen3-4B-Thinking-2507'), ModelType.qwen3);
      expect(
        map(
          'superwhisper/s1-mini',
          arch:
              'Dense 0.6B ASR-transcript normalizer, Qwen3ForCausalLM '
              'finetune',
        ),
        ModelType.qwen3,
      );
    });

    test('qwen2-family by id or class token', () {
      expect(map('Qwen/Qwen2-VL-2B-Instruct'), ModelType.qwen);
      expect(map('llava-hf/llava-onevision-qwen2-0.5b-ov-hf'), ModelType.qwen);
      expect(
        map(
          'WeiboAI/VibeThinker-3B',
          arch: 'Dense 3B math/reasoning model, Qwen2ForCausalLM, 36 layers',
        ),
        ModelType.qwen,
      );
    });

    test('architecture prose naming a compute lineage must NOT map — only '
        'ids and exact class tokens do', () {
      // "Llama-architecture granite decoder" describes compute, not the chat
      // contract; ModelType.llama here would break iOS conversations.
      expect(
        map(
          'ibm-granite/granite-docling-258M',
          arch:
              'VLM: SigLIP encoder feeding a Llama-architecture granite '
              'decoder',
        ),
        isNull,
      );
      expect(
        map(
          'HuggingFaceTB/SmolVLM2-500M-Video-Instruct',
          arch: 'SigLIP + SmolLM2-360M (Llama) decoder',
        ),
        isNull,
      );
    });

    test('llama and phi by id, with word boundaries', () {
      expect(map('meta-llama/Llama-3.2-1B-Instruct'), ModelType.llama);
      expect(map('microsoft/Phi-4-mini-instruct'), ModelType.phi);
      expect(map('someorg/ollama-export'), isNull); // 'llama' inside a word
      expect(map('someorg/delphi-model'), isNull); // 'phi' without a digit
    });

    test('gemma generations: gemma4 is the E2B/E4B generation, not a 4B '
        'gemma 3', () {
      expect(map('google/gemma-4-e2b-it'), ModelType.gemma4);
      expect(map('google/gemma-3-4b-it'), ModelType.gemmaIt);
      expect(map('google/gemma-4b-it'), ModelType.gemmaIt);
      expect(map('google/functiongemma-270m'), ModelType.functionGemma);
    });

    test('families outside the enum stay null — the app supplies one', () {
      expect(map('LiquidAI/LFM2.5-1.2B-Instruct'), isNull);
      expect(map('mistralai/Ministral-3-3B-Instruct-2512'), isNull);
      expect(map('HuggingFaceTB/SmolLM3-3B'), isNull);
      expect(
        map(
          'nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16',
          arch: 'NemotronHForCausalLM hybrid',
        ),
        isNull,
      );
    });
  });

  group('vendored reader stays logic-identical to the reference '
      '(readers/dart 0.2.0)', () {
    final lfm = LitertlmManifest.fromJson(lfmFixture());

    test('explicit gpu request survives the variant pick', () {
      final r = lfm.resolve(platform: 'android', backend: 'gpu')!;
      expect(r.file, 'LFM2.5-1.2B-Instruct_int4_gpu.litertlm');
      expect(r.backend, 'gpu');
    });

    test('explicit backend wins over the platform recommendation; caveats '
        'surface in notes', () {
      final r = lfm.resolve(platform: 'ios', backend: 'gpu')!;
      expect(r.file, 'LFM2.5-1.2B-Instruct_int4_gpu.litertlm');
      expect(r.backend, 'gpu');
      expect(r.variant.backends, contains(r.backend));
      expect(r.notes.any((n) => n.contains('Metal')), isTrue);
    });

    test('explicit backend counts only recommendations naming it', () {
      final r = lfm.resolve(platform: 'macos', backend: 'cpu')!;
      expect(r.file, 'LFM2.5-1.2B-Instruct_int8.litertlm');
      expect(r.backend, 'cpu');
    });

    test('a backend no variant lists resolves to null, never a substitute', () {
      expect(lfm.resolve(backend: 'npu'), isNull);
      expect(lfm.resolve(platform: 'android', backend: 'npu'), isNull);
    });

    test('deviceClass with no matching entry falls back with a note in '
        'reason', () {
      final r = lfm.resolve(platform: 'android', deviceClass: 'budget-2019')!;
      expect(
        r.reason,
        contains('no budget-2019 entry; using the midrange recommendation'),
      );
    });

    test('recommended row naming an unverified backend is ignored', () {
      final m = LitertlmManifest.fromJson({
        'manifest_schema': '0.1.0',
        'repo': 'test/malformed',
        'generated': '2026-08-26',
        'model': {'display_name': 'Malformed'},
        'variants': [
          {
            'file': 'm.litertlm',
            'quantization': 'int8',
            'backends': ['cpu'],
            'default_backend': 'cpu',
            'recommended': [
              {'platform': 'android', 'backend': 'gpu'},
            ],
          },
        ],
      });
      final r = m.resolve(platform: 'android')!;
      expect(r.backend, 'cpu');
    });

    test('resolution URLs follow the fetched revision', () {
      final pinned = LitertlmManifest.fromJson(manifest(), revision: 'abc123');
      expect(pinned.resolve()!.url, contains('/resolve/abc123/'));
      expect(
        pinned.resolve(revision: 'deadbeef')!.url,
        contains('/resolve/deadbeef/'),
      );
      expect(lfm.resolve()!.url, contains('/resolve/main/'));
    });

    test('0.1.1 declared channel set flows through, tool-call included; '
        'absent → empty', () {
      final m = LitertlmManifest.fromJson({
        'manifest_schema': '0.1.1',
        'repo': 'test/channels',
        'generated': '2026-08-27',
        'model': {
          'display_name': 'Channels',
          'capabilities': {
            'thinking': {
              'declared': true,
              'channel': {'start': '<think>', 'end': '</think>'},
            },
            'channels': [
              {
                'name': 'thought',
                'start': '<think>',
                'end': '</think>',
                'is_reasoning': true,
              },
              {
                'name': 'tool_call',
                'start': '<tool_call>',
                'end': '</tool_call>',
              },
            ],
          },
        },
        'variants': [
          {
            'file': 'a.litertlm',
            'quantization': 'q',
            'backends': ['cpu'],
          },
        ],
      });
      expect(m.declaredChannels.length, 2);
      expect(m.declaredChannels[1].name, 'tool_call');
      expect(m.declaredChannels[0].isReasoning, isTrue);
      expect(lfm.declaredChannels, isEmpty);
    });
  });
}
