// Runs the resolver over a snapshot of EVERY live manifest the
// hf-to-litertlm converter had shipped as of 2026-09-02 (28 repos, 51
// variants — fixtures/README.md regenerates it), across every platform key
// core can send and every backend hint. Guards the resolver against the real
// published data: the invariants hold for all 896 combinations, every one of
// them is pinned to the reference reader's selection
// (fixtures/reference_goldens.json), and the dataset-shape counts fail loudly
// if regenerated fixtures change the distributions the mapping decisions were
// made against.
//
// Offline by design: the fixtures are committed and the resolver's fetch seam
// is fed from them, so nothing here touches the network. The opt-in live leg
// (live_hugging_face_test.dart) is what checks the snapshot against Hugging
// Face.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelType;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show ResolvedHfModel;
import 'package:flutter_gemma_litertlm/src/manifest/litertlm_manifest_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

const _platforms = [
  null,
  'android',
  'ios',
  'macos',
  'windows',
  'linux',
  'web',
  'unknown',
];
// npu: no shipped variant is verified on it, so it exercises the hint-drop
// lane (the resolver resolves without the hint) on every repo.
const _hints = [
  null,
  PreferredBackend.cpu,
  PreferredBackend.gpu,
  PreferredBackend.npu,
];

String _wire(PreferredBackend b) => switch (b) {
  PreferredBackend.cpu => 'cpu',
  PreferredBackend.gpu => 'gpu',
  PreferredBackend.npu => 'npu',
};

/// Key of a row in fixtures/reference_goldens.json — same shape the
/// regeneration dump in fixtures/README.md writes.
String _goldenKey(String repo, String? platform, PreferredBackend? hint) =>
    '$repo|${platform ?? "-"}|${hint == null ? "-" : _wire(hint)}';

void main() {
  final dir = Directory('test/manifest/fixtures');
  final fixtures =
      dir
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.endsWith('.json') &&
                !f.path.endsWith('reference_goldens.json'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final byRepo = <String, Map<String, dynamic>>{};
  for (final f in fixtures) {
    final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    byRepo[json['repo'] as String] = json;
  }

  Future<ResolvedHfModel> resolve(
    String repo, {
    String? platform,
    PreferredBackend? hint,
  }) => LitertlmManifestResolver(
    fetch: (url, headers) async => jsonEncode(byRepo[repo]),
  ).resolve(repo, platform: platform, preferredBackend: hint);

  test('the snapshot has the documented shape (28 repos, 51 variants)', () {
    expect(byRepo.length, 28);
    final variants = byRepo.values
        .expand((m) => m['variants'] as List)
        .cast<Map<String, dynamic>>()
        .toList();
    expect(variants.length, 51);
    // The common case is NO recommended rows — 32 of 51 variants — so the
    // default_backend fallback is the resolver's main path, not an edge.
    expect(variants.where((v) => v['recommended'] == null).length, 32);
    // Every published variant carries the integrity pair.
    for (final v in variants) {
      expect(v['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(v['size_bytes'], greaterThan(0));
    }
  });

  test('invariants hold for every repo × platform × backend hint', () async {
    var combinations = 0;
    for (final entry in byRepo.entries) {
      final repo = entry.key;
      final manifest = entry.value;
      final model = manifest['model'] as Map<String, dynamic>;
      final capabilities =
          model['capabilities'] as Map<String, dynamic>? ?? const {};
      final thinking =
          capabilities['thinking'] as Map<String, dynamic>? ?? const {};
      final variantsByFile = {
        for (final v
            in (manifest['variants'] as List).cast<Map<String, dynamic>>())
          v['file'] as String: v,
      };

      for (final platform in _platforms) {
        for (final hint in _hints) {
          combinations++;
          final r = await resolve(repo, platform: platform, hint: hint);
          final where = '$repo p=$platform hint=$hint';

          // The chosen file is one of the repo's variants, addressed at the
          // repo's own /resolve/ path (encoded per segment, as core's
          // fromHuggingFace does).
          final variant = variantsByFile[r.file];
          expect(variant, isNotNull, reason: where);
          expect(
            r.url,
            'https://huggingface.co/$repo/resolve/main/'
            '${r.file.split('/').map(Uri.encodeComponent).join('/')}',
            reason: where,
          );

          // Identity comes from that same variant.
          expect(r.sha256, variant!['sha256'], reason: where);
          expect(r.sizeBytes, variant['size_bytes'], reason: where);

          // The resolved backend is always in the variant's VERIFIED list
          // (all shipped backends are cpu/gpu, so the enum mapping is never
          // silently null).
          expect(r.runtime.preferredBackend, isNotNull, reason: where);
          expect(
            (variant['backends'] as List).cast<String>(),
            contains(_wire(r.runtime.preferredBackend!)),
            reason: where,
          );

          // Spec resolution rule: a hint some variant is verified on is a
          // FILTER — the result keeps exactly that backend. A hint nothing
          // lists is dropped: the result must equal the same resolve with no
          // hint (platform preserved), never a substitute for the request.
          if (hint != null) {
            final anyListsHint = variantsByFile.values.any(
              (v) => (v['backends'] as List).contains(_wire(hint)),
            );
            if (anyListsHint) {
              expect(r.runtime.preferredBackend, hint, reason: where);
              expect(
                r.notes.where((n) => n.contains('resolved without that hint')),
                isEmpty,
                reason: where,
              );
            } else {
              final noHint = await resolve(repo, platform: platform);
              expect(r.file, noHint.file, reason: where);
              expect(
                r.runtime.preferredBackend,
                noHint.runtime.preferredBackend,
                reason: where,
              );
              // The drop is on the record: the no-hint notes plus one line
              // naming the dropped hint.
              expect(r.notes, [
                ...noHint.notes,
                'No variant of "$repo" is verified on the requested '
                    '${_wire(hint)} backend; resolved without that hint '
                    '(${_wire(r.runtime.preferredBackend!)}).',
              ], reason: where);
            }
          }

          // Model-level fields land regardless of variant choice.
          expect(r.runtime.maxTokens, model['context_length'], reason: where);
          expect(
            r.runtime.isThinking,
            thinking['declared'] == true,
            reason: where,
          );
          expect(
            r.runtime.supportImage,
            capabilities['vision'] == true,
            reason: where,
          );
          expect(
            r.runtime.supportAudio,
            capabilities['audio'] == true,
            reason: where,
          );
        }
      }
    }
    expect(combinations, 28 * _platforms.length * _hints.length);
  });

  test('every combination matches the reference reader '
      '(fixtures/reference_goldens.json)', () async {
    // Generated by running the hf-to-litertlm readers/dart reference reader
    // over the same fixtures (fixtures/README.md). Two rows worth knowing
    // when reading a mismatch: Qwen3-4B-Thinking has NO android
    // recommendation, so android falls through to smallest-file +
    // default_backend — (block-32 file, cpu) since the 08-31 reship moved
    // that file's default off GPU — while ios/macos pick the recommended
    // block-128 file on gpu.
    final goldens =
        jsonDecode(
              File(
                'test/manifest/fixtures/reference_goldens.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(goldens.length, 28 * _platforms.length * _hints.length);

    final mismatches = <String>[];
    for (final repo in byRepo.keys) {
      for (final platform in _platforms) {
        for (final hint in _hints) {
          final key = _goldenKey(repo, platform, hint);
          final golden = goldens[key] as Map<String, dynamic>?;
          expect(
            golden,
            isNotNull,
            reason: 'no reference row for $key — regenerate the goldens',
          );
          final r = await resolve(repo, platform: platform, hint: hint);
          final backend = _wire(r.runtime.preferredBackend!);
          if (r.file != golden!['file'] || backend != golden['backend']) {
            mismatches.add(
              '$key: resolver=(${r.file}, $backend) '
              'reference=(${golden['file']}, ${golden['backend']})',
            );
          }
        }
      }
    }
    expect(mismatches, isEmpty, reason: mismatches.join('\n'));
  });

  test('session_defaults distribution: the floor is set exactly where the '
      'published data sets it', () async {
    const withFloor = {
      'litert-community/DeepSeek-R1-Distill-Qwen-7B',
      'litert-community/Falcon-H1-Tiny-R-0.6B',
      'litert-community/LFM2.5-1.2B-Thinking',
      'litert-community/LFM2.5-2.6B',
      'litert-community/Nanbeige4.2-3B',
      'litert-community/Qwen3-4B-Thinking-2507',
      'litert-community/VibeThinker-3B',
      'litert-community/granite-4.2-3b',
    };
    for (final repo in byRepo.keys) {
      final r = await resolve(repo);
      expect(
        r.runtime.minOutputTokens,
        withFloor.contains(repo) ? 2048 : isNull,
        reason: repo,
      );
    }
  });

  test('modelType over the shipped catalog: mapped only where the family is '
      'certain, null everywhere else', () async {
    const expected = <String, ModelType?>{
      // deepseek outranks the qwen in the distill's id.
      'litert-community/DeepSeek-R1-Distill-Qwen-7B': ModelType.deepSeek,
      'litert-community/Qwen3-4B-Thinking-2507': ModelType.qwen3,
      // Qwen3ForCausalLM class token — the id alone hides the family.
      'mlboydaisuke/S1-mini-LiteRT': ModelType.qwen3,
      // Qwen3.5 is ChatML without qwen3's /no_think injection.
      'litert-community/Qwen3.5-0.8B': ModelType.qwen,
      'litert-community/Qwen3.5-2B': ModelType.qwen,
      'litert-community/Qwen3.5-4B': ModelType.qwen,
      'litert-community/Qwen2-VL-2B': ModelType.qwen,
      'litert-community/LLaVA-OneVision-0.5B': ModelType.qwen,
      // Qwen2ForCausalLM class token.
      'litert-community/VibeThinker-3B': ModelType.qwen,
      // Everything else — LFM2.5, granite, SmolLM/SmolVLM, Ministral,
      // Nanbeige, Nemotron, Falcon-H1, HunYuan-MT, Shieldstral — has no
      // ModelType, and prose like "Llama-architecture granite decoder" must
      // not create one.
      'litert-community/LFM2.5-1.2B-Instruct': null,
      'litert-community/LFM2.5-1.2B-JP': null,
      'litert-community/LFM2.5-1.2B-Thinking': null,
      'litert-community/LFM2.5-2.6B': null,
      'litert-community/LFM2.5-230M': null,
      'litert-community/Ministral-3-3B-Instruct-2512': null,
      'litert-community/Nanbeige4.2-3B': null,
      'litert-community/Nemotron-3-Nano-4B': null,
      'litert-community/SmolLM3-3B': null,
      'litert-community/SmolVLM2-500M': null,
      'litert-community/Falcon-H1-Tiny-R-0.6B': null,
      'litert-community/Hy-MT2-1.8B': null,
      'litert-community/Shieldstral-1.0-3B': null,
      'litert-community/granite-4.0-h-350m': null,
      'litert-community/granite-4.2-3b': null,
      'litert-community/granite-docling-258M': null,
      'mlboydaisuke/Mordant-3B-Think-LiteRT': null,
      // A Qwen3.5 finetune whose id drops the family and whose architecture
      // names it only in prose ("Qwen3.5-0.8B gated-delta hybrid …"): the
      // conservative mapping returns null rather than guess — the app
      // supplies the type (`r.modelType ?? ModelType.general`).
      'mlboydaisuke/OvisOCR2-LiteRT': null,
      'mlboydaisuke/Tashkeel-350M-v2-LiteRT': null,
    };
    expect(expected.length, byRepo.length);
    for (final entry in expected.entries) {
      final r = await resolve(entry.key);
      expect(r.modelType, entry.value, reason: entry.key);
    }
  });

  test('thinking is declared by exactly the 15 repos that declare it, with '
      'their markers intact in the manifest', () async {
    const thinkingRepos = {
      'litert-community/DeepSeek-R1-Distill-Qwen-7B',
      'litert-community/Falcon-H1-Tiny-R-0.6B',
      'litert-community/LFM2.5-1.2B-Instruct',
      'litert-community/LFM2.5-1.2B-JP',
      'litert-community/LFM2.5-1.2B-Thinking',
      'litert-community/LFM2.5-2.6B',
      'litert-community/LFM2.5-230M',
      'litert-community/Nanbeige4.2-3B',
      'litert-community/Nemotron-3-Nano-4B',
      'litert-community/Qwen3-4B-Thinking-2507',
      'litert-community/SmolLM3-3B',
      'litert-community/VibeThinker-3B',
      'litert-community/granite-4.2-3b',
      'mlboydaisuke/Mordant-3B-Think-LiteRT',
      'mlboydaisuke/S1-mini-LiteRT',
    };
    for (final repo in byRepo.keys) {
      final r = await resolve(repo);
      expect(r.runtime.isThinking, thinkingRepos.contains(repo), reason: repo);
    }
    // The channel markers stay exact in the data (whitespace included) even
    // though v1 consumes only the declared bool — worth pinning so a future
    // createSession(defaults:) can rely on them.
    final qwen = byRepo['litert-community/Qwen3-4B-Thinking-2507']!;
    final channel =
        (((qwen['model'] as Map)['capabilities'] as Map)['thinking']
                as Map)['channel']
            as Map;
    expect(channel['start'], '<think>\n');
    expect(channel['end'], '\n</think>');
  });
}
