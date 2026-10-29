import 'dart:convert';
import 'dart:io';

import 'package:model_registry/check.dart';
import 'package:model_registry/dart_names.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _rev = '0123456789abcdef0123456789abcdef01234567';
const _sha1 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _sha2 =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, Object?> _artifact(
  String path, {
  String sha = _sha1,
  String? name,
}) => {
  'repo': 'litert-community/example',
  'revision': _rev,
  'path': path,
  'sha256': sha,
  'size': 1024,
  'install_filename': name ?? path.split('/').last,
};

Map<String, Object?> _llm() => {
  'id': 'tiny-llm',
  'kind': 'llm',
  'package': 'flutter_edge_ai_litertlm',
  'display_name': 'Tiny LLM',
  'family': 'tiny',
  'arch_class': 'dense',
  'license': 'apache-2.0',
  'license_url': 'https://www.apache.org/licenses/LICENSE-2.0',
  'model_type': 'gemmaIt',
  'capabilities': {
    'image': false,
    'audio': false,
    'function_calls': true,
    'thinking': false,
  },
  'runtime': {'max_tokens': 1024, 'preferred_backend': 'gpu'},
  'variants': [
    {
      'slug': 'generic',
      'file_type': 'litertlm',
      'file': _artifact('tiny.litertlm'),
    },
    {
      'slug': 'web',
      'file_type': 'litertlm',
      'web_bundle': true,
      'file': _artifact('tiny-web.litertlm', sha: _sha2),
    },
    {
      'slug': 'npu-sm8750',
      'file_type': 'litertlm',
      'npu': {'vendor': 'qualcomm', 'soc': 'SM8750'},
      'fixed_max_tokens': 1280,
      'runtime': {'preferred_backend': 'npu'},
      'file': _artifact('tiny_sm8750.litertlm', sha: _shaNpu),
    },
  ],
};

Map<String, Object?> _embedder() => {
  'id': 'tiny-embedder',
  'kind': 'embedder',
  'package': 'flutter_edge_ai_litertlm',
  'display_name': 'Tiny Embedder',
  'family': 'tiny',
  'arch_class': 'encoder',
  'license': 'apache-2.0',
  'license_url': 'https://www.apache.org/licenses/LICENSE-2.0',
  'modalities': ['text'],
  'variants': [
    {
      'slug': 'seq256',
      'file_type': 'tflite',
      'file': _artifact(
        'emb_256.tflite',
        name: 'emb_256__rev-0123456789ab.tflite',
      ),
      'tokenizer': _artifact(
        'sentencepiece.model',
        sha: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        name: 'emb-seq256__sentencepiece__rev-0123456789ab.model',
      ),
      'rag_profile_id': 'tiny-seq256-rev-0123456789ab-v1',
      'dimension': 768,
      'max_input_tokens': 256,
    },
  ],
};

Map<String, Object?> _stt() => {
  'id': 'tiny-stt',
  'kind': 'stt',
  'package': 'flutter_edge_ai_speech',
  'display_name': 'Tiny STT',
  'family': 'whisper',
  'arch_class': 'speech-recognition',
  'license': 'mit',
  'license_url': 'https://opensource.org/license/mit',
  'stt_type': 'whisper',
  'variants': [
    {
      'slug': 'f32',
      'file_type': 'tflite',
      'file': _artifact('stt.tflite'),
      'tokenizer': _artifact('tokenizer.json', sha: _sha2),
    },
  ],
};

Map<String, Object?> _tts() => {
  'id': 'tiny-tts',
  'kind': 'tts',
  'package': 'flutter_edge_ai_speech',
  'display_name': 'Tiny TTS',
  'family': 'matcha',
  'arch_class': 'speech-synthesis',
  'license': 'mit',
  'license_url': 'https://opensource.org/license/mit',
  'tts_type': 'matcha',
  'variants': [
    {
      'slug': 'bundle',
      'files': [_artifact('a.tflite'), _artifact('b.json', sha: _sha2)],
    },
  ],
};

const _shaNpu =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

/// What inspect_bundle_test.dart would read from [_llm]'s three files.
Map<String, String> _llmFacts({
  Map<String, Object?> generic = const {'size': 1024, 'npu_target': null},
  Map<String, Object?> npu = const {
    'size': 1024,
    'npu_target': 'Qualcomm/SM8750',
    'kv_cache_length': 1280,
  },
}) => {
  'derived/$_sha1.json': jsonEncode(generic),
  'derived/$_sha2.json': jsonEncode({'size': 1024, 'npu_target': null}),
  'derived/$_shaNpu.json': jsonEncode(npu),
};

/// A registry in a temp dir; [entries] are written as models/<id>.yaml.
Directory _registry(
  List<Map<String, Object?>> entries, {
  Map<String, String> extraFiles = const {},
}) {
  final dir = Directory.systemTemp.createTempSync('model_registry_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final models = Directory(p.join(dir.path, 'models'))..createSync();
  for (final e in entries) {
    // JSON is YAML, and it keeps the fixture independent of a YAML writer.
    File(
      p.join(models.path, '${e['id']}.yaml'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(e));
  }
  for (final MapEntry(:key, :value) in extraFiles.entries) {
    File(p.join(dir.path, key))
      ..createSync(recursive: true)
      ..writeAsStringSync(value);
  }
  return dir;
}

List<String> _problems(
  List<Map<String, Object?>> entries, {
  Map<String, String> extraFiles = const {},
}) => [
  for (final problem in checkRegistry(
    _registry(entries, extraFiles: extraFiles),
  ).problems)
    problem.toString(),
];

/// [entry] with [edit] applied to a deep copy.
Map<String, Object?> _with(
  Map<String, Object?> entry,
  void Function(Map<String, Object?> e) edit,
) {
  final copy = jsonDecode(jsonEncode(entry)) as Map<String, Object?>;
  edit(copy);
  return copy;
}

Map<String, Object?> _variant(Map<String, Object?> e, int i) =>
    (e['variants'] as List)[i] as Map<String, Object?>;

void main() {
  test('a valid entry of every kind passes', () {
    expect(
      _problems([_llm(), _embedder(), _stt(), _tts()], extraFiles: _llmFacts()),
      isEmpty,
    );
  });

  group('each rule fails its own fixture', () {
    void fails(
      String name,
      List<Map<String, Object?>> entries,
      String message, {
      Map<String, String> extraFiles = const {},
    }) {
      test(name, () {
        final problems = _problems(entries, extraFiles: extraFiles);
        expect(
          problems,
          contains(contains(message)),
          reason: problems.join('\n'),
        );
      });
    }

    fails(
      'a /resolve/main/ URL',
      [_llm()],
      'a /resolve/main/ URL',
      extraFiles: {
        'notes.md': 'https://huggingface.co/x/y/resolve/main/z.litertlm',
      },
    );
    fails('a revision that is not a commit', [
      _with(
        _llm(),
        (e) => (_variant(e, 0)['file'] as Map)['revision'] = 'main',
      ),
    ], 'is not a 40-hex commit');
    fails(
      'two entries with one id',
      [_llm()],
      'duplicate of models/',
      extraFiles: {'models/tiny-llm-copy.yaml': jsonEncode(_llm())},
    );
    fails(
      'an id that is not its file name',
      [_llm()],
      '"tiny-llm" differs from the file name',
      extraFiles: {'models/tiny-llm-copy.yaml': jsonEncode(_llm())},
    );
    fails('an NPU build without its compiled context', [
      _with(_llm(), (e) => _variant(e, 2).remove('fixed_max_tokens')),
    ], 'an NPU build has a compiled context');
    fails('an NPU build that does not prefer npu', [
      _with(_llm(), (e) => _variant(e, 2).remove('runtime')),
    ], 'an NPU build must prefer npu');
    fails('Cyrillic text', [
      _with(
        _llm(),
        // Built from code points: no Cyrillic in the source itself.
        (e) => e['display_name'] =
            'Tiny ${String.fromCharCodes([0x43c, 0x43e, 0x434, 0x435, 0x43b, 0x44c])}',
      ),
    ], 'Cyrillic text');
    fails('an unknown key', [
      _with(_llm(), (e) => _variant(e, 2)['fixed_max_token'] = 1280),
    ], 'fixed_max_token: unknown key');
    fails('an unknown model type', [
      _with(_llm(), (e) => e['model_type'] = 'gemma'),
    ], '"gemma" is not one of');
    fails('an unknown NPU vendor', [
      _with(_llm(), (e) => (_variant(e, 2)['npu'] as Map)['vendor'] = 'apple'),
    ], '"apple" is not one of');
    fails('a duplicate slug', [
      _with(_llm(), (e) => _variant(e, 1)['slug'] = 'generic'),
    ], 'duplicate "generic"');
    fails('a withheld variant without an issue', [
      _with(_llm(), (e) => _variant(e, 0)['withhold'] = {'reason': 'crashes'}),
    ], 'withhold.issue: required');
    fails('one install name for two different files', [
      _llm(),
      _with(_llm(), (e) {
        e['id'] = 'other-llm';
        (_variant(e, 0)['file'] as Map)['sha256'] = _sha2;
      }),
    ], 'install_filename "tiny.litertlm" is also');
    fails('an image embedder without an image profile', [
      _with(_embedder(), (e) => e['modalities'] = ['text', 'image']),
    ], 'image_rag_profile_id: required');
    fails('a .tflite embedder without its tokenizer', [
      _with(_embedder(), (e) => _variant(e, 0).remove('tokenizer')),
    ], 'needs its tokenizer');
    fails('a speech model in the wrong package', [
      _with(_stt(), (e) => e['package'] = 'flutter_edge_ai_litertlm'),
    ], 'is not one of flutter_edge_ai_speech');
    fails(
      'a frozen field changed after it was published',
      [
        _with(
          _embedder(),
          (e) => _variant(e, 0)['rag_profile_id'] = 'tiny-seq256-v2',
        ),
      ],
      'frozen since this release',
      extraFiles: {
        'published/flutter_edge_ai_litertlm/1.16.0.json': jsonEncode({
          'variants': {
            'tiny-embedder/seq256': frozenValues(_variant(_embedder(), 0)),
          },
        }),
      },
    );
    for (final (field, value) in [
      ('sha256', 'f' * 64),
      ('install_filename', 'tiny-seq256__other.model'),
    ]) {
      fails(
        'a tokenizer $field changed after it was published, same profile id',
        [
          _with(
            _embedder(),
            (e) => (_variant(e, 0)['tokenizer'] as Map)[field] = value,
          ),
        ],
        'tokenizer_$field: frozen since this release',
        extraFiles: {
          'published/flutter_edge_ai_litertlm/1.16.0.json': jsonEncode({
            'variants': {
              'tiny-embedder/seq256': frozenValues(_variant(_embedder(), 0)),
            },
          }),
        },
      );
    }
    fails(
      'an LLM install name with another extension',
      [
        _with(
          _llm(),
          (e) => (_variant(e, 0)['file'] as Map)['install_filename'] = 'x.task',
        ),
      ],
      'an LLM keeps its file\'s extension',
      extraFiles: _llmFacts(),
    );
    fails('an STT tokenizer install name that is not its file name', [
      _with(
        _stt(),
        (e) => (_variant(e, 0)['tokenizer'] as Map)['install_filename'] =
            'other.json',
      ),
    ], 'core installs an STT model under its URL\'s file name');
    fails(
      'a slug whose Dart getter is a reserved word',
      [_with(_llm(), (e) => _variant(e, 1)['slug'] = 'default')],
      '"default" is a Dart reserved word',
      extraFiles: _llmFacts(),
    );
    fails(
      'a slug whose Dart getter shadows a CatalogModel member',
      [_with(_llm(), (e) => _variant(e, 1)['slug'] = 'variants')],
      '"variants" is taken',
      extraFiles: _llmFacts(),
    );
    fails('two models with one Dart getter', [
      _with(_llm(), (e) => e['id'] = 'tiny-2-5'),
      _with(_llm(), (e) {
        e['id'] = 'tiny-2.5';
        for (final v in e['variants'] as List) {
          final file = (v as Map)['file'] as Map;
          file['install_filename'] = 'b_${file['install_filename']}';
        }
      }),
    ], '"tiny2_5" is taken');
    fails('a .litertlm file never read', [
      _llm(),
    ], 'no facts read from its bytes');
    fails(
      'an NPU target the bytes contradict',
      [_llm()],
      'declared Qualcomm/SM8750, but the file is compiled for Qualcomm/SM8650',
      extraFiles: _llmFacts(
        npu: {
          'size': 1024,
          'npu_target': 'Qualcomm/SM8650',
          'kv_cache_length': 1280,
        },
      ),
    );
    fails(
      'a compiled file declared generic',
      [_llm()],
      'the file is compiled for Google/Tensor_G5; declare that npu target',
      extraFiles: _llmFacts(
        generic: {'size': 1024, 'npu_target': 'Google/Tensor_G5'},
      ),
    );
    fails(
      'a compiled context the bytes contradict',
      [_llm()],
      'the decode graph is built for a 4096-token cache',
      extraFiles: _llmFacts(
        npu: {
          'size': 1024,
          'npu_target': 'Qualcomm/SM8750',
          'kv_cache_length': 4096,
        },
      ),
    );
    fails(
      'a runtime context above the compiled one',
      [
        _with(_llm(), (e) {
          _variant(e, 2)['runtime'] = {
            'max_tokens': 2048,
            'preferred_backend': 'npu',
          };
        }),
      ],
      '2048 is more than the compiled 1280',
      extraFiles: _llmFacts(),
    );
    fails(
      'a native file that is not a LiteRT-LM container',
      [_llm()],
      'its bytes are not a LiteRT-LM container (notLitertlm)',
      extraFiles: _llmFacts(generic: {'size': 1024, 'problem': 'notLitertlm'}),
    );
    fails(
      'facts no registry file references',
      [_llm()],
      'no registry file has this sha256',
      extraFiles: {
        ..._llmFacts(),
        'derived/${'e' * 64}.json': jsonEncode({'size': 1}),
      },
    );
    fails(
      'a published variant deleted',
      [_llm()],
      'published variant is gone',
      extraFiles: {
        'published/flutter_edge_ai_litertlm/1.16.0.json': jsonEncode({
          'variants': {
            'tiny-embedder/seq256': frozenValues(_variant(_embedder(), 0)),
          },
        }),
      },
    );
  });

  test('Dart names keep numbers apart', () {
    expect(dartMemberName('gemma-4-e2b-it'), 'gemma4E2bIt');
    expect(dartMemberName('qwen3-0.6b'), 'qwen3_0_6b');
    expect(dartMemberName('qwen2.5-1.5b-instruct'), 'qwen2_5_1_5bInstruct');
    expect(dartMemberName('npu-tensor-g6'), 'npuTensorG6');
    expect(dartClassName('LiteRtLm', 'gemma-4-e2b-it'), 'LiteRtLmGemma4E2bIt');
  });

  test('the repo registry passes', () {
    final registry = Directory(
      p.normalize(p.join('..', '..', 'model_registry')),
    );
    final result = checkRegistry(registry);
    expect(result.problems.map((x) => '$x'), isEmpty);
    expect(result.entries, isNotEmpty);
  });

  test('every repo entry is plain YAML the generator can read', () {
    final models = Directory(
      p.normalize(p.join('..', '..', 'model_registry', 'models')),
    );
    for (final file in models.listSync().whereType<File>()) {
      expect(
        loadYaml(file.readAsStringSync()),
        isA<YamlMap>(),
        reason: file.path,
      );
    }
  });
}
