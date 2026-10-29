// The rules every registry entry must satisfy. `registry.dart check` runs them
// on every pull request, so a broken entry never reaches a generated file.
//
// The schema is closed: a key this file does not know is an error, so a typo
// ("fixed_max_token") cannot silently drop a fact.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dart_names.dart';

/// One broken rule, anchored to the file and the key path it was found at.
final class Problem {
  Problem(this.file, this.where, this.message);

  final String file;
  final String where;
  final String message;

  @override
  String toString() => '$file: $where: $message';
}

/// A registry entry as read from `models/<id>.yaml`.
final class Entry {
  Entry(this.file, this.data);

  final String file;
  final Map<String, Object?> data;

  String get id => data['id'] as String? ?? '';
}

/// The result of [checkRegistry].
final class CheckResult {
  CheckResult(this.entries, this.problems);

  final List<Entry> entries;
  final List<Problem> problems;

  int get variantCount => entries.fold(
    0,
    (n, e) => n + ((e.data['variants'] as List?)?.length ?? 0),
  );
}

const _kinds = {'llm', 'embedder', 'stt', 'tts'};

/// The package that ships each kind. The schema admits the other engines
/// (`task`, `gguf`, `onnx`, `builtIn`) as file types; their packages are added
/// here when their catalogs are.
const _packageFor = {
  'llm': {'flutter_edge_ai_litertlm'},
  'embedder': {'flutter_edge_ai_litertlm'},
  'stt': {'flutter_edge_ai_speech'},
  'tts': {'flutter_edge_ai_speech'},
};

const _fileTypes = {'litertlm', 'tflite', 'task', 'gguf', 'onnx', 'builtIn'};
const _fileTypesFor = {
  'flutter_edge_ai_litertlm': {
    'llm': {'litertlm'},
    'embedder': {'litertlm', 'tflite'},
  },
  'flutter_edge_ai_speech': {
    'stt': {'tflite'},
  },
};

/// `ModelType` in packages/flutter_edge_ai/lib/src/model.dart. The generated
/// catalog will not compile if this drifts from the enum.
const _modelTypes = {
  'general',
  'gemmaIt',
  'gemma4',
  'deepSeek',
  'qwen',
  'qwen3',
  'qwen35',
  'llama',
  'hammer',
  'functionGemma',
  'phi',
};
const _backends = {'cpu', 'gpu', 'npu'};
const _npuVendors = {'qualcomm', 'intel', 'google-tensor', 'mediatek'};
const _sttTypes = {'moonshine', 'whisper', 'parakeet'};
const _ttsTypes = {'matcha', 'qwen3', 'inflect'};
const _modalities = {'text', 'image', 'audio'};
const _gated = {'auto', 'manual'};

const _modelKeys = {
  'common': {
    'id',
    'kind',
    'package',
    'display_name',
    'family',
    'arch_class',
    'license',
    'license_url',
    'variants',
    'deprecated',
  },
  'llm': {'model_type', 'capabilities', 'runtime'},
  'embedder': {'modalities'},
  'stt': {'stt_type'},
  'tts': {'tts_type'},
};

const _variantKeys = {
  'common': {'slug', 'example', 'withhold', 'withhold_backends', 'deprecated'},
  'llm': {
    'file_type',
    'file',
    'web_bundle',
    'npu',
    'fixed_max_tokens',
    'capabilities',
    'runtime',
  },
  'embedder': {
    'file_type',
    'file',
    'tokenizer',
    'npu',
    'rag_profile_id',
    'image_rag_profile_id',
    'dimension',
    'max_input_tokens',
    'preferred_backend',
    'web_bundle',
  },
  'stt': {'file_type', 'file', 'tokenizer', 'npu'},
  'tts': {'files'},
};

const _artifactKeys = {
  'repo',
  'revision',
  'path',
  'sha256',
  'size',
  'install_filename',
  'gated',
};

final _idPattern = RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)*$');
final _repoPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$',
);
final _revisionPattern = RegExp(r'^[0-9a-f]{40}$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _cyrillic = RegExp(r'[Ѐ-ӿ]');

/// Checks every entry under `<registryDir>/models/` and, when present, the
/// published snapshots under `<registryDir>/published/`.
CheckResult checkRegistry(Directory registryDir) {
  final problems = <Problem>[];
  final entries = <Entry>[];
  final modelsDir = Directory(p.join(registryDir.path, 'models'));
  if (!modelsDir.existsSync()) {
    problems.add(Problem(modelsDir.path, '-', 'directory is missing'));
    return CheckResult(entries, problems);
  }

  for (final file in _filesUnder(registryDir)) {
    final rel = p.relative(file.path, from: registryDir.path);
    final text = file.readAsStringSync();
    final line = text.split('\n').indexWhere(_cyrillic.hasMatch);
    if (line >= 0) {
      problems.add(Problem(rel, 'line ${line + 1}', 'Cyrillic text'));
    }
    if (text.contains('/resolve/main/')) {
      problems.add(
        Problem(rel, '-', 'a /resolve/main/ URL; pin a 40-hex revision'),
      );
    }
  }

  final yamlFiles =
      modelsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yaml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in yamlFiles) {
    final rel = p.relative(file.path, from: registryDir.path);
    final Object? doc;
    try {
      doc = _plain(loadYaml(file.readAsStringSync()));
    } on YamlException catch (e) {
      problems.add(Problem(rel, '-', 'not YAML: ${e.message}'));
      continue;
    }
    if (doc is! Map<String, Object?>) {
      problems.add(Problem(rel, '-', 'not a mapping'));
      continue;
    }
    final entry = Entry(rel, doc);
    entries.add(entry);
    _checkModel(entry, p.basenameWithoutExtension(file.path), problems);
  }

  _checkAcrossEntries(entries, problems);
  _checkDartNames(entries, problems);
  _checkDerived(registryDir, entries, problems);
  _checkPublished(registryDir, entries, problems);
  _checkReleasedCatalogs(registryDir, entries, problems);
  return CheckResult(entries, problems);
}

/// Each model's getter in its package's generated namespace class.
void _checkDartNames(List<Entry> entries, List<Problem> problems) {
  final taken = <String, Map<String, String>>{};
  for (final e in entries) {
    if (!_idPattern.hasMatch(e.id)) continue;
    // litertlm has a namespace per kind (LiteRtLmModels, LiteRtEmbedders);
    // speech keeps STT and TTS in one (LiteRtSpeechModels).
    final package = '${e.data['package']}';
    final scope = package == 'flutter_edge_ai_speech'
        ? package
        : '$package/${e.data['kind']}';
    final names = taken[scope] ??= {};
    final name = dartMemberName(e.id);
    final problem = dartNameProblem(name, {
      ...catalogNamespaceMembers,
      ...names.keys,
    });
    if (problem != null) {
      final other = names[name];
      problems.add(
        Problem(
          e.file,
          '.id',
          'its Dart getter: $problem${other == null ? '' : ' by $other'}',
        ),
      );
    }
    names[name] = e.file;
  }
}

/// The vendor names LiteRT's compiler stamps, by registry vendor.
const _stampVendor = {
  'qualcomm': 'Qualcomm',
  'google-tensor': 'Google',
  'mediatek': 'MediaTek',
  'intel': 'IntelOpenVINO',
};

/// The registry against `derived/<sha256>.json`: what
/// packages/flutter_edge_ai_litertlm/test/catalog/inspect_bundle_test.dart read
/// from each file's bytes. A declared fact that the bytes contradict is an
/// error; so is an NPU build or a `.litertlm` file that was never read.
void _checkDerived(
  Directory registryDir,
  List<Entry> entries,
  List<Problem> problems,
) {
  final dir = Directory(p.join(registryDir.path, 'derived'));
  final facts = <String, Map<String, Object?>>{};
  if (dir.existsSync()) {
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final rel = p.relative(file.path, from: registryDir.path);
      try {
        facts[p.basenameWithoutExtension(file.path)] =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      } on FormatException catch (e) {
        problems.add(Problem(rel, '-', 'not JSON: ${e.message}'));
      }
    }
  }
  final used = <String>{};
  for (final e in entries) {
    final variants = e.data['variants'];
    if (variants is! List) continue;
    for (var i = 0; i < variants.length; i++) {
      final v = variants[i];
      if (v is! Map<String, Object?>) continue;
      final where = '.variants[$i](${v['slug']})';
      for (final key in ['tokenizer']) {
        if (v[key] case {'sha256': final String sha}) used.add(sha);
      }
      for (final f in (v['files'] as List?) ?? const []) {
        if (f case {'sha256': final String sha}) used.add(sha);
      }
      final file = v['file'];
      if (file is! Map<String, Object?>) continue;
      final sha = file['sha256'];
      final path = file['path'];
      if (sha is! String || path is! String) continue;
      used.add(sha);
      final npu = v['npu'];
      final read = facts[sha];
      if (read == null) {
        if (path.endsWith('.litertlm') || npu != null) {
          problems.add(
            Problem(
              e.file,
              '$where.file',
              'no facts read from its bytes; run inspect_bundle_test.dart',
            ),
          );
        }
        continue;
      }
      if (read['size'] != file['size']) {
        problems.add(
          Problem(
            e.file,
            '$where.file.size',
            '${file['size']}, but the bytes read were ${read['size']}',
          ),
        );
      }
      if (read['problem'] case final String problem) {
        if (v['web_bundle'] != true) {
          problems.add(
            Problem(
              e.file,
              '$where.file',
              'its bytes are not a LiteRT-LM container ($problem); only a web '
                  'bundle may be another format',
            ),
          );
        }
        continue;
      }
      final stamp = read['npu_target'];
      final declared = npu is Map
          ? '${_stampVendor[npu['vendor']] ?? npu['vendor']}/${npu['soc']}'
          : null;
      if (stamp != declared) {
        problems.add(
          Problem(
            e.file,
            '$where.npu',
            declared == null
                ? 'the file is compiled for $stamp; declare that npu target'
                : 'declared $declared, but the file is compiled for '
                      '${stamp ?? 'no NPU'}',
          ),
        );
      }
      final cache = read['kv_cache_length'];
      if (e.data['kind'] == 'llm' && npu != null && cache is int) {
        if (v['fixed_max_tokens'] != cache) {
          problems.add(
            Problem(
              e.file,
              '$where.fixed_max_tokens',
              '${v['fixed_max_tokens']}, but the decode graph is built for a '
                  '$cache-token cache',
            ),
          );
        }
        final runtime = v['runtime'];
        final maxTokens = runtime is Map ? runtime['max_tokens'] : null;
        if (maxTokens is int && maxTokens > cache) {
          problems.add(
            Problem(
              e.file,
              '$where.runtime.max_tokens',
              '$maxTokens is more than the compiled $cache',
            ),
          );
        }
      }
    }
  }
  for (final sha in facts.keys) {
    if (!used.contains(sha)) {
      problems.add(
        Problem('derived/$sha.json', '-', 'no registry file has this sha256'),
      );
    }
  }
}

Iterable<File> _filesUnder(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => !p.basename(f.path).startsWith('.'));

/// YAML nodes as plain Dart maps and lists, so rules compare values only.
Object? _plain(Object? node) => switch (node) {
  YamlMap m => {for (final e in m.entries) e.key.toString(): _plain(e.value)},
  YamlList l => [for (final v in l) _plain(v)],
  _ => node,
};

final class _Ctx {
  _Ctx(this.entry, this.problems);

  final Entry entry;
  final List<Problem> problems;

  void error(String where, String message) =>
      problems.add(Problem(entry.file, where, message));

  void keys(String where, Map<String, Object?> map, Set<String> allowed) {
    for (final key in map.keys) {
      if (!allowed.contains(key)) error('$where.$key', 'unknown key');
    }
  }

  T? need<T extends Object>(
    String where,
    Map<String, Object?> map,
    String key,
  ) {
    final value = map[key];
    if (value == null) {
      error('$where.$key', 'required');
      return null;
    }
    if (value is T) return value;
    error('$where.$key', 'must be ${_typeName<T>()}, is ${value.runtimeType}');
    return null;
  }

  T? opt<T extends Object>(String where, Map<String, Object?> map, String key) {
    if (!map.containsKey(key) || map[key] == null) return null;
    return need<T>(where, map, key);
  }

  void oneOf(String where, Object? value, Set<String> allowed) {
    if (value != null && !allowed.contains(value)) {
      error(where, '"$value" is not one of ${allowed.join(', ')}');
    }
  }
}

String _typeName<T extends Object>() => switch (T) {
  const (String) => 'a string',
  const (int) => 'an integer',
  const (bool) => 'true or false',
  const (List) => 'a list',
  const (Map<String, Object?>) => 'a mapping',
  _ => '$T',
};

void _checkModel(Entry entry, String fileId, List<Problem> problems) {
  final c = _Ctx(entry, problems);
  final m = entry.data;
  final kind = c.need<String>('', m, 'kind');
  if (kind != null && !_kinds.contains(kind)) {
    c.error('.kind', '"$kind" is not one of ${_kinds.join(', ')}');
    return;
  }
  c.keys('', m, {..._modelKeys['common']!, ..._modelKeys[kind] ?? const {}});

  final id = c.need<String>('', m, 'id');
  if (id != null) {
    if (!_idPattern.hasMatch(id)) {
      c.error('.id', '"$id" must be lowercase words joined by - or .');
    }
    if (id != fileId) c.error('.id', '"$id" differs from the file name');
  }
  final package = c.need<String>('', m, 'package');
  if (kind != null) c.oneOf('.package', package, _packageFor[kind]!);
  for (final key in ['display_name', 'family', 'arch_class', 'license']) {
    c.need<String>('', m, key);
  }
  final licenseUrl = c.need<String>('', m, 'license_url');
  if (licenseUrl != null && !licenseUrl.startsWith('https://')) {
    c.error('.license_url', 'must be an https URL');
  }
  _checkDeprecated(c, '', m);

  switch (kind) {
    case 'llm':
      c.oneOf('.model_type', c.need<String>('', m, 'model_type'), _modelTypes);
      final caps = c.need<Map<String, Object?>>('', m, 'capabilities');
      if (caps != null) _checkCapabilities(c, '.capabilities', caps, all: true);
      final runtime = c.need<Map<String, Object?>>('', m, 'runtime');
      if (runtime != null) _checkRuntime(c, '.runtime', runtime, all: true);
    case 'embedder':
      final modalities = c.need<List>('', m, 'modalities');
      for (final x in modalities ?? const []) {
        c.oneOf('.modalities', x, _modalities);
      }
      if (modalities != null && !modalities.contains('text')) {
        c.error('.modalities', 'must include text');
      }
    case 'stt':
      c.oneOf('.stt_type', c.need<String>('', m, 'stt_type'), _sttTypes);
    case 'tts':
      c.oneOf('.tts_type', c.need<String>('', m, 'tts_type'), _ttsTypes);
  }

  final variants = c.need<List>('', m, 'variants');
  if (variants == null || kind == null || package == null) return;
  if (variants.isEmpty) c.error('.variants', 'empty');
  final slugs = <String>{};
  for (var i = 0; i < variants.length; i++) {
    final where = '.variants[$i]';
    final v = variants[i];
    if (v is! Map<String, Object?>) {
      c.error(where, 'not a mapping');
      continue;
    }
    final slug = c.need<String>(where, v, 'slug');
    if (slug != null) {
      if (!_idPattern.hasMatch(slug)) {
        c.error(
          '$where.slug',
          '"$slug" must be lowercase words joined by - or .',
        );
      } else if (dartNameProblem(dartMemberName(slug), {
            ...catalogModelMembers,
            for (final s in slugs) dartMemberName(s),
          })
          case final problem?) {
        c.error('$where.slug', 'its Dart getter: $problem');
      }
      if (!slugs.add(slug)) c.error('$where.slug', 'duplicate "$slug"');
    }
    _checkVariant(
      c,
      '$where${slug == null ? '' : '($slug)'}',
      v,
      kind,
      package,
      m,
    );
  }
}

void _checkVariant(
  _Ctx c,
  String where,
  Map<String, Object?> v,
  String kind,
  String package,
  Map<String, Object?> model,
) {
  c.keys(where, v, {..._variantKeys['common']!, ..._variantKeys[kind]!});
  final example = c.opt<List>(where, v, 'example');
  for (final x in example ?? const []) {
    if (x is! String) c.error('$where.example', 'entries must be strings');
  }
  _checkWithhold(
    c,
    '$where.withhold',
    c.opt<Map<String, Object?>>(where, v, 'withhold'),
  );
  final byBackend = c.opt<Map<String, Object?>>(where, v, 'withhold_backends');
  for (final MapEntry(:key, :value) in (byBackend ?? const {}).entries) {
    c.oneOf('$where.withhold_backends', key, _backends);
    _checkWithhold(
      c,
      '$where.withhold_backends.$key',
      value is Map<String, Object?> ? value : null,
      required: true,
    );
  }
  _checkDeprecated(c, where, v);

  if (kind == 'tts') {
    final files = c.need<List>(where, v, 'files');
    if (files != null && files.isEmpty) c.error('$where.files', 'empty');
    for (var i = 0; i < (files?.length ?? 0); i++) {
      final f = files![i];
      if (f is Map<String, Object?>) {
        _checkArtifact(c, '$where.files[$i]', f);
      } else {
        c.error('$where.files[$i]', 'not a mapping');
      }
    }
    return;
  }

  final fileType = c.need<String>(where, v, 'file_type');
  c.oneOf('$where.file_type', fileType, _fileTypes);
  final allowed = _fileTypesFor[package]?[kind];
  if (fileType != null && allowed != null && !allowed.contains(fileType)) {
    c.error('$where.file_type', '$package does not load "$fileType" for $kind');
  }
  if (fileType == 'builtIn') {
    if (v.containsKey('file'))
      c.error('$where.file', 'a builtIn model has no file');
  } else {
    final file = c.need<Map<String, Object?>>(where, v, 'file');
    if (file != null) _checkArtifact(c, '$where.file', file);
  }

  final npu = c.opt<Map<String, Object?>>(where, v, 'npu');
  if (npu != null) {
    c.keys('$where.npu', npu, {'vendor', 'soc'});
    c.oneOf(
      '$where.npu.vendor',
      c.need<String>('$where.npu', npu, 'vendor'),
      _npuVendors,
    );
    c.need<String>('$where.npu', npu, 'soc');
    if (v['web_bundle'] == true) {
      c.error('$where.npu', 'a web bundle is never compiled for an NPU');
    }
  }
  c.opt<bool>(where, v, 'web_bundle');

  switch (kind) {
    case 'llm':
      if (npu != null) {
        final fixed = v['fixed_max_tokens'];
        if (fixed == null) {
          c.error(
            '$where.fixed_max_tokens',
            'an NPU build has a compiled context; read it with `registry inspect`',
          );
        } else if (fixed is! int || fixed <= 0) {
          c.error('$where.fixed_max_tokens', 'must be a positive integer');
        }
      } else if (v.containsKey('fixed_max_tokens')) {
        c.error(
          '$where.fixed_max_tokens',
          'only an NPU build has a fixed context',
        );
      }
      final caps = c.opt<Map<String, Object?>>(where, v, 'capabilities');
      if (caps != null)
        _checkCapabilities(c, '$where.capabilities', caps, all: false);
      final runtime = c.opt<Map<String, Object?>>(where, v, 'runtime');
      if (runtime != null)
        _checkRuntime(c, '$where.runtime', runtime, all: false);
      if (npu != null && runtime?['preferred_backend'] != 'npu') {
        c.error(
          '$where.runtime.preferred_backend',
          'an NPU build must prefer npu',
        );
      }
      if (npu == null && runtime?['preferred_backend'] == 'npu') {
        c.error(
          '$where.runtime.preferred_backend',
          'npu without an npu target',
        );
      }
    case 'embedder':
      final profile = c.need<String>(where, v, 'rag_profile_id');
      if (profile != null &&
          !_idPattern.hasMatch(profile.replaceAll('_', '-'))) {
        c.error(
          '$where.rag_profile_id',
          'must be lowercase words joined by - . or _',
        );
      }
      final imageProfile = c.opt<String>(where, v, 'image_rag_profile_id');
      final modalities = (model['modalities'] as List?) ?? const [];
      if (modalities.contains('image') && imageProfile == null) {
        c.error(
          '$where.image_rag_profile_id',
          'required for an image embedder',
        );
      }
      if (!modalities.contains('image') && imageProfile != null) {
        c.error(
          '$where.image_rag_profile_id',
          'the model does not embed images',
        );
      }
      final dimension = c.need<int>(where, v, 'dimension');
      if (dimension != null && dimension <= 0)
        c.error('$where.dimension', 'must be positive');
      final maxInput = c.need<int>(where, v, 'max_input_tokens');
      if (maxInput != null && maxInput <= 0) {
        c.error('$where.max_input_tokens', 'must be positive');
      }
      final backend = c.opt<String>(where, v, 'preferred_backend');
      c.oneOf('$where.preferred_backend', backend, _backends);
      if ((npu != null) != (backend == 'npu')) {
        c.error(
          '$where.preferred_backend',
          'npu exactly when the variant has an npu target',
        );
      }
      final tokenizer = c.opt<Map<String, Object?>>(where, v, 'tokenizer');
      if (tokenizer != null) _checkArtifact(c, '$where.tokenizer', tokenizer);
      if (fileType == 'tflite' && tokenizer == null) {
        c.error('$where.tokenizer', 'a .tflite embedder needs its tokenizer');
      }
      if (fileType == 'litertlm' && tokenizer != null) {
        c.error(
          '$where.tokenizer',
          'a .litertlm bundle carries its own tokenizer',
        );
      }
    case 'stt':
      final tokenizer = c.need<Map<String, Object?>>(where, v, 'tokenizer');
      if (tokenizer != null) _checkArtifact(c, '$where.tokenizer', tokenizer);
  }
  // Core installs an STT model's two files under their URL's file name,
  // whatever the catalog says: a different install name would be found only
  // after the download. An LLM is installed under the catalog's name, which
  // keeps the file's extension (the engines read it).
  if (kind == 'stt') {
    for (final key in ['file', 'tokenizer']) {
      if (v[key] case {
        'path': final String path,
        'install_filename': final String name,
      } when name != p.posix.basename(path)) {
        c.error(
          '$where.$key.install_filename',
          '"$name": core installs an STT model under its URL\'s file name, '
              '"${p.posix.basename(path)}"',
        );
      }
    }
  }
  if (kind == 'llm') {
    if (v['file'] case {
      'path': final String path,
      'install_filename': final String name,
    } when p.posix.extension(name) != p.posix.extension(path)) {
      c.error(
        '$where.file.install_filename',
        '"$name": an LLM keeps its file\'s extension, '
            '"${p.posix.extension(path)}"',
      );
    }
  }
}

void _checkCapabilities(
  _Ctx c,
  String where,
  Map<String, Object?> caps, {
  required bool all,
}) {
  const keys = {'image', 'audio', 'function_calls', 'thinking'};
  c.keys(where, caps, keys);
  for (final key in keys) {
    if (all) {
      c.need<bool>(where, caps, key);
    } else {
      c.opt<bool>(where, caps, key);
    }
  }
}

void _checkRuntime(
  _Ctx c,
  String where,
  Map<String, Object?> runtime, {
  required bool all,
}) {
  c.keys(where, runtime, {'max_tokens', 'preferred_backend'});
  final maxTokens = all
      ? c.need<int>(where, runtime, 'max_tokens')
      : c.opt<int>(where, runtime, 'max_tokens');
  if (maxTokens != null && maxTokens <= 0) {
    c.error('$where.max_tokens', 'must be positive');
  }
  final backend = all
      ? c.need<String>(where, runtime, 'preferred_backend')
      : c.opt<String>(where, runtime, 'preferred_backend');
  c.oneOf('$where.preferred_backend', backend, _backends);
}

void _checkWithhold(
  _Ctx c,
  String where,
  Map<String, Object?>? w, {
  bool required = false,
}) {
  if (w == null) {
    if (required) c.error(where, 'must be a mapping with reason and issue');
    return;
  }
  c.keys(where, w, {'reason', 'issue'});
  c.need<String>(where, w, 'reason');
  final issue = c.need<String>(where, w, 'issue');
  if (issue != null && !issue.startsWith('https://')) {
    c.error('$where.issue', 'must link the issue that explains it');
  }
}

void _checkDeprecated(_Ctx c, String where, Map<String, Object?> map) {
  final d = c.opt<Map<String, Object?>>(where, map, 'deprecated');
  if (d == null) return;
  c.keys('$where.deprecated', d, {'reason', 'use'});
  c.need<String>('$where.deprecated', d, 'reason');
  c.opt<String>('$where.deprecated', d, 'use');
}

void _checkArtifact(_Ctx c, String where, Map<String, Object?> a) {
  c.keys(where, a, _artifactKeys);
  final repo = c.need<String>(where, a, 'repo');
  if (repo != null && !_repoPattern.hasMatch(repo)) {
    c.error('$where.repo', '"$repo" is not owner/name');
  }
  final revision = c.need<String>(where, a, 'revision');
  if (revision != null && !_revisionPattern.hasMatch(revision)) {
    c.error('$where.revision', '"$revision" is not a 40-hex commit');
  }
  final path = c.need<String>(where, a, 'path');
  if (path != null &&
      (path.isEmpty ||
          path.startsWith('/') ||
          path.split('/').contains('..'))) {
    c.error('$where.path', '"$path" is not a path inside the repo');
  }
  final sha = c.need<String>(where, a, 'sha256');
  if (sha != null && !_sha256Pattern.hasMatch(sha)) {
    c.error('$where.sha256', 'not 64 lowercase hex digits');
  }
  final size = c.need<int>(where, a, 'size');
  if (size != null && size <= 0) c.error('$where.size', 'must be positive');
  final name = c.need<String>(where, a, 'install_filename');
  if (name != null && !isPortableFileName(name)) {
    c.error(
      '$where.install_filename',
      'must be a bare file name every platform takes: no path separator, '
          'control character or one of <>:"|?*, no trailing dot or space, '
          'not a Windows device name (CON, NUL, COM1, …)',
    );
  }
  c.oneOf('$where.gated', a['gated'], _gated);
}

/// An artifact with the entry and the key path it was declared at.
typedef _Located = ({Entry entry, String where, Map<String, Object?> artifact});

Iterable<_Located> _artifacts(Entry e) sync* {
  final variants = e.data['variants'];
  if (variants is! List) return;
  for (var i = 0; i < variants.length; i++) {
    final v = variants[i];
    if (v is! Map<String, Object?>) continue;
    final at = '.variants[$i](${v['slug']})';
    for (final key in ['file', 'tokenizer']) {
      if (v[key] case final Map<String, Object?> a) {
        yield (entry: e, where: '$at.$key', artifact: a);
      }
    }
    if (v['files'] case final List files) {
      for (var j = 0; j < files.length; j++) {
        if (files[j] case final Map<String, Object?> a) {
          yield (entry: e, where: '$at.files[$j]', artifact: a);
        }
      }
    }
  }
}

void _checkAcrossEntries(List<Entry> entries, List<Problem> problems) {
  final ids = <String, String>{};
  for (final e in entries) {
    final previous = ids[e.id];
    if (previous != null) {
      problems.add(Problem(e.file, '.id', 'duplicate of $previous'));
    } else {
      ids[e.id] = e.file;
    }
  }

  // The installed identity of a file: core keys an LLM by the URL's file name
  // and an embedder by its install file name, both in one shared directory;
  // speech files are prefixed with their model id. Two different files under
  // one identity would read as "already installed" and load the wrong bytes.
  final identities = <String, _Located>{};
  for (final e in entries) {
    final scoped = e.data['kind'] == 'stt' || e.data['kind'] == 'tts';
    for (final located in _artifacts(e)) {
      final a = located.artifact;
      final sha = a['sha256'];
      final name = a['install_filename'];
      if (name is String && sha is String) {
        // macOS and Windows file systems ignore case: `Model.litertlm` and
        // `model.litertlm` are one file there.
        final key = (scoped ? '${e.id}/$name' : name).toLowerCase();
        final seen = identities[key];
        if (seen == null) {
          identities[key] = located;
        } else if (seen.artifact['sha256'] != sha) {
          problems.add(
            Problem(
              e.file,
              located.where,
              'install_filename "$name" is also ${seen.entry.file} ${seen.where} '
              'with different bytes',
            ),
          );
        }
      }
    }
  }

  final profiles = <String, ({String file, Object? dimension})>{};
  for (final e in entries) {
    if (e.data['kind'] != 'embedder') continue;
    for (final v in (e.data['variants'] as List?) ?? const []) {
      if (v is! Map<String, Object?>) continue;
      for (final key in ['rag_profile_id', 'image_rag_profile_id']) {
        final id = v[key];
        if (id is! String) continue;
        final seen = profiles[id];
        if (seen == null) {
          profiles[id] = (file: e.file, dimension: v['dimension']);
        } else if (seen.dimension != v['dimension']) {
          problems.add(
            Problem(
              e.file,
              '.variants(${v['slug']}).$key',
              '"$id" has dimension ${seen.dimension} in ${seen.file}',
            ),
          );
        }
      }
    }
  }
}

/// Fields a published version froze: changing one strands what users already
/// installed or indexed. `published/<package>/<version>.json` maps a variant
/// id (`<model id>/<slug>`) to the values it shipped with.
///
/// The tokenizer is frozen with the model: a `.tflite` embedder that reads
/// another tokenizer writes other vectors under the same `rag_profile_id`.
const frozenFields = [
  'install_filename',
  'sha256',
  'tokenizer_install_filename',
  'tokenizer_sha256',
  'rag_profile_id',
  'image_rag_profile_id',
];

void _checkPublished(
  Directory registryDir,
  List<Entry> entries,
  List<Problem> problems,
) {
  final dir = Directory(p.join(registryDir.path, 'published'));
  if (!dir.existsSync()) return;
  final current = <String, Map<String, Object?>>{
    for (final e in entries)
      for (final v in (e.data['variants'] as List?) ?? const [])
        if (v is Map<String, Object?>) '${e.id}/${v['slug']}': frozenValues(v),
  };
  final snapshots =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in snapshots) {
    final rel = p.relative(file.path, from: registryDir.path);
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      problems.add(Problem(rel, '-', 'not JSON: ${e.message}'));
      continue;
    }
    final variants = json is Map ? json['variants'] : null;
    if (variants is! Map) {
      problems.add(Problem(rel, '.variants', 'required'));
      continue;
    }
    for (final MapEntry(:key, :value) in variants.entries) {
      final now = current[key];
      if (now == null) {
        problems.add(
          Problem(
            rel,
            key.toString(),
            'published variant is gone; withhold it instead of deleting it '
            '(a variant a release shipped is never removed; one no release '
            'shipped may be)',
          ),
        );
        continue;
      }
      for (final field in frozenFields) {
        final was = (value as Map)[field];
        if (was != now[field]) {
          problems.add(
            Problem(
              rel,
              '$key.$field',
              'frozen since this release: "$was", now "${now[field]}"; add a new '
                  'variant instead',
            ),
          );
        }
      }
    }
  }
}

/// A package whose CHANGELOG has released its catalog (a `## X.Y.Z` section
/// naming "Model catalog") has `published/<package>/<version>.json` for that
/// version and every later one: the freeze [_checkPublished] holds variants
/// to, which a deleted snapshot would otherwise switch off without a word.
void _checkReleasedCatalogs(
  Directory registryDir,
  List<Entry> entries,
  List<Problem> problems,
) {
  final root = p.dirname(p.absolute(registryDir.path));
  // A registry outside a repository (the tests' fixtures) has no packages.
  if (!Directory(p.join(root, 'packages')).existsSync()) return;
  final packages = {for (final e in entries) '${e.data['package']}'}.toList()
    ..sort();
  final heading = RegExp(r'^## (\d+\.\d+\.\d+\S*)\s*$');
  final namesAVersion = RegExp(r'^## .*\d+\.\d+\.\d+');
  for (final package in packages) {
    final rel = p.join('packages', package, 'CHANGELOG.md');
    final changelog = File(p.join(root, rel));
    if (!changelog.existsSync()) {
      problems.add(
        Problem(rel, '-', 'missing: it says which versions shipped a catalog'),
      );
      continue;
    }
    final released = <String>[]; // newest first
    final withCatalog = <String>{};
    String? section;
    for (final (i, line) in changelog.readAsLinesSync().indexed) {
      if (heading.firstMatch(line) case final m?) {
        section = m.group(1);
        released.add(section!);
      } else if (line.startsWith('## ')) {
        section = null;
        // A release heading in another form would be read as no release.
        if (namesAVersion.hasMatch(line)) {
          problems.add(
            Problem(
              rel,
              'line ${i + 1}',
              '"$line" names a version but is not "## X.Y.Z"',
            ),
          );
        }
      } else if (section != null &&
          line.toLowerCase().contains('model catalog')) {
        withCatalog.add(section);
      }
    }
    // The published snapshots anchor it too: a version newer than the oldest
    // one frozen shipped the catalog, whatever its CHANGELOG says.
    final frozenDir = Directory(p.join(registryDir.path, 'published', package));
    final frozen = frozenDir.existsSync()
        ? {
            for (final f in frozenDir.listSync().whereType<File>())
              if (f.path.endsWith('.json')) p.basenameWithoutExtension(f.path),
          }
        : const <String>{};
    final first = [
      released.lastIndexWhere(withCatalog.contains),
      released.lastIndexWhere(frozen.contains),
    ].reduce((a, b) => a > b ? a : b);
    for (final version in released.take(first + 1)) {
      final snapshot = p.join('published', package, '$version.json');
      if (!File(p.join(registryDir.path, snapshot)).existsSync()) {
        problems.add(
          Problem(
            snapshot,
            '-',
            '$package $version released its catalog (CHANGELOG.md), and this '
                'snapshot of it is missing; run `registry.dart freeze $package` '
                'at that version, or restore the file',
          ),
        );
      }
    }
  }
}

/// Whether [name] is a file name core installs on every platform: the rule
/// of core's `FileNameUtils.validatePortableFileNameSegment`.
bool isPortableFileName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains('\\') &&
    !RegExp(r'[\u0000-\u001F\u007F-\u009F<>:"|?*]').hasMatch(name) &&
    !name.endsWith('.') &&
    !name.endsWith(' ') &&
    !RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
      caseSensitive: false,
    ).hasMatch(name.split('.').first);

/// The frozen values of one variant, as a published snapshot records them.
Map<String, Object?> frozenValues(Map<String, Object?> v) {
  final file = v['file'];
  final files = v['files'];
  final tokenizer = v['tokenizer'];
  return {
    'install_filename': file is Map
        ? file['install_filename']
        : files is List
        ? [for (final f in files) (f as Map)['install_filename']].join(',')
        : null,
    'sha256': file is Map
        ? file['sha256']
        : files is List
        ? [for (final f in files) (f as Map)['sha256']].join(',')
        : null,
    'tokenizer_install_filename': tokenizer is Map
        ? tokenizer['install_filename']
        : null,
    'tokenizer_sha256': tokenizer is Map ? tokenizer['sha256'] : null,
    'rag_profile_id': v['rag_profile_id'],
    'image_rag_profile_id': v['image_rag_profile_id'],
  };
}
