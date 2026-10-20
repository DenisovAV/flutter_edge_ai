// Generates the packages' catalogs from the registry. `generate` writes them;
// `check` fails when a checked-in file differs from what this produces, so a
// registry change and its generated code land in one commit.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'check.dart';
import 'dart_names.dart';

/// A generated file: where it goes, relative to the repo root, and its text.
typedef GeneratedFile = ({String path, String content});

/// Every generated file for [entries], with the facts in `<registry>/derived`.
List<GeneratedFile> generateAll(Directory registryDir, List<Entry> entries) {
  final derived = _readDerived(Directory(p.join(registryDir.path, 'derived')));
  return [
    (
      path:
          'packages/flutter_edge_ai_litertlm/lib/src/catalog/generated/'
          'litert_catalog.g.dart',
      content: generateLiteRtCatalog(entries, derived),
    ),
  ];
}

Map<String, Map<String, Object?>> _readDerived(Directory dir) => {
  if (dir.existsSync())
    for (final f in dir.listSync().whereType<File>())
      if (f.path.endsWith('.json'))
        p.basenameWithoutExtension(f.path):
            jsonDecode(f.readAsStringSync()) as Map<String, Object?>,
};

const _header = '''
// GENERATED from model_registry/models/*.yaml by tool/model_registry:
//   cd tool/model_registry && dart run bin/registry.dart generate
// Do not edit: change the registry and generate again. `registry.dart check`
// fails when this file is stale.
// ignore_for_file: camel_case_types, non_constant_identifier_names
''';

/// `flutter_edge_ai_litertlm`'s catalog part: its LLMs and embedders.
String generateLiteRtCatalog(
  List<Entry> entries,
  Map<String, Map<String, Object?>> derived,
) {
  final mine =
      entries
          .where((e) => e.data['package'] == 'flutter_edge_ai_litertlm')
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  final llms = [
    for (final e in mine)
      if (e.data['kind'] == 'llm') e.data,
  ];
  final embedders = [
    for (final e in mine)
      if (e.data['kind'] == 'embedder') e.data,
  ];
  final out = StringBuffer(_header)
    ..writeln()
    ..writeln("part of '../litert_catalog.dart';")
    ..writeln();
  _namespace(
    out,
    name: 'LiteRtLmModels',
    modelType: 'LiteRtLmModel',
    classPrefix: 'LiteRtLm',
    doc:
        'The LLMs `flutter_edge_ai_litertlm` runs: `.litertlm` files pinned to '
        'Hugging Face commits.',
    models: llms,
  );
  _namespace(
    out,
    name: 'LiteRtEmbedders',
    modelType: 'LiteRtEmbedderModel',
    classPrefix: 'LiteRtEmbedder',
    doc:
        'The embedding models `flutter_edge_ai_litertlm` runs: EmbeddingGemma 2 '
        '`.litertlm` bundles, and `.tflite` models with their tokenizers, '
        'pinned to Hugging Face commits.',
    models: embedders,
  );
  for (final m in llms) {
    _llmModel(out, m, derived);
  }
  for (final m in embedders) {
    _embedderModel(out, m);
  }
  return out.toString();
}

void _namespace(
  StringBuffer out, {
  required String name,
  required String modelType,
  required String classPrefix,
  required String doc,
  required List<Map<String, Object?>> models,
}) {
  out
    ..writeln('/// $doc')
    ..writeln('abstract final class $name {')
    ..writeln('  /// Every model, in one catalog.')
    ..writeln(
      "  static const catalog = LiteRtCatalog._('flutter_edge_ai_litertlm', all);",
    )
    ..writeln()
    ..writeln('  /// Every model.')
    ..writeln('  static const List<$modelType> all = [');
  for (final m in models) {
    out.writeln('    ${dartMemberName(m['id']! as String)},');
  }
  out
    ..writeln('  ];')
    ..writeln()
    ..writeln('  /// The model with [id], or null.')
    ..writeln('  static $modelType? byId(String id) {')
    ..writeln('    for (final m in all) {')
    ..writeln('      if (m.id == id) return m;')
    ..writeln('    }')
    ..writeln('    return null;')
    ..writeln('  }');
  for (final m in models) {
    final id = m['id']! as String;
    out
      ..writeln()
      ..writeln('  /// ${m['display_name']} (`$id`).')
      ..writeln(
        '  static const ${dartMemberName(id)} = '
        '${dartClassName(classPrefix, id)}._();',
      );
  }
  out
    ..writeln('}')
    ..writeln();
}

List<Map<String, Object?>> _offered(Map<String, Object?> model) => [
  for (final v in model['variants']! as List)
    if ((v as Map<String, Object?>)['withhold'] == null) v,
];

void _modelClass(
  StringBuffer out,
  Map<String, Object?> m, {
  required String base,
  required String variantType,
  required String classPrefix,
  required List<String> extraSuper,
  required void Function(Map<String, Object?> v, String constName) variant,
}) {
  final id = m['id']! as String;
  final model = dartMemberName(id);
  final offered = _offered(m);
  String constName(Map<String, Object?> v) =>
      '_$model\$${dartMemberName(v['slug']! as String)}';
  out
    ..writeln('/// ${m['display_name']} (`$id`), ${m['license']}.')
    ..writeln('final class ${dartClassName(classPrefix, id)} extends $base {')
    ..writeln('  const ${dartClassName(classPrefix, id)}._()')
    ..writeln('    : super._(')
    ..writeln('        id: ${_str(id)},')
    ..writeln('        displayName: ${_str(m['display_name']! as String)},')
    ..writeln('        family: ${_str(m['family']! as String)},');
  for (final line in extraSuper) {
    out.writeln('        $line');
  }
  out
    ..writeln('        license: ${_str(m['license']! as String)},')
    ..writeln('        licenseUrl: ${_str(m['license_url']! as String)},')
    ..writeln('        variants: const [');
  for (final v in offered) {
    out.writeln('          ${constName(v)},');
  }
  out
    ..writeln('        ],')
    ..writeln('      );');
  for (final v in offered) {
    final file = v['file']! as Map<String, Object?>;
    out
      ..writeln()
      ..writeln('  /// `${file['path']}`, ${_size(file['size']! as int)}.')
      ..writeln(
        '  $variantType get ${dartMemberName(v['slug']! as String)} => '
        '${constName(v)};',
      );
  }
  out
    ..writeln('}')
    ..writeln();
  for (final v in offered) {
    variant(v, constName(v));
  }
}

void _llmModel(
  StringBuffer out,
  Map<String, Object?> m,
  Map<String, Map<String, Object?>> derived,
) {
  final id = m['id']! as String;
  final modelCaps = m['capabilities']! as Map<String, Object?>;
  final modelRuntime = m['runtime']! as Map<String, Object?>;
  _modelClass(
    out,
    m,
    base: 'LiteRtLmModel',
    variantType: 'LiteRtLmVariant',
    classPrefix: 'LiteRtLm',
    extraSuper: ['archClass: ${_str(m['arch_class']! as String)},'],
    variant: (v, name) {
      final file = v['file']! as Map<String, Object?>;
      final caps = {
        ...modelCaps,
        ...(v['capabilities'] as Map<String, Object?>? ?? const {}),
      };
      final runtime = v['runtime'] as Map<String, Object?>? ?? const {};
      final npu = v['npu'] as Map<String, Object?>?;
      final fixed = v['fixed_max_tokens'] as int?;
      final web = v['web_bundle'] == true;
      final maxTokens =
          runtime['max_tokens'] ??
          (npu != null ? fixed : null) ??
          modelRuntime['max_tokens'];
      final backend = npu != null
          ? 'npu'
          : web
          ? 'gpu'
          : (runtime['preferred_backend'] ?? modelRuntime['preferred_backend']);
      final withheld = (v['withhold_backends'] as Map?)?.keys.toSet() ?? {};
      final text = _textBackends(
        derived[file['sha256']],
        file,
      ).where((b) => !withheld.contains(b)).toList();
      out
        ..writeln('const $name = LiteRtLmVariant._(')
        ..writeln("  id: ${_str('$id/${v['slug']}')},")
        ..writeln('  modelId: ${_str(id)},')
        ..writeln('  file: ${_artifact(file)},')
        ..writeln('  modelType: ModelType.${m['model_type']},')
        ..writeln('  runtimeDefaults: ModelRuntimeDefaults(')
        ..writeln('    maxTokens: $maxTokens,')
        ..writeln('    preferredBackend: PreferredBackend.$backend,')
        ..writeln('    supportImage: ${caps['image']},')
        ..writeln('    supportAudio: ${caps['audio']},')
        ..writeln('  ),')
        ..writeln('  supportsImage: ${caps['image']},')
        ..writeln('  supportsAudio: ${caps['audio']},')
        ..writeln('  supportsFunctionCalls: ${caps['function_calls']},')
        ..writeln('  supportsThinking: ${caps['thinking']},')
        ..writeln('  isWebBundle: $web,')
        ..writeln(
          '  textBackends: {${text.map((b) => 'PreferredBackend.$b').join(', ')}},',
        );
      if (npu != null) {
        out
          ..writeln('  npuTarget: ${_npuTarget(npu)},')
          ..writeln('  requiredMaxTokens: $fixed,');
      }
      out
        ..writeln(');')
        ..writeln();
    },
  );
}

void _embedderModel(StringBuffer out, Map<String, Object?> m) {
  final id = m['id']! as String;
  final modalities = (m['modalities']! as List).cast<String>();
  _modelClass(
    out,
    m,
    base: 'LiteRtEmbedderModel',
    variantType: 'LiteRtEmbedderVariant',
    classPrefix: 'LiteRtEmbedder',
    extraSuper: const [],
    variant: (v, name) {
      final file = v['file']! as Map<String, Object?>;
      final tokenizer = v['tokenizer'] as Map<String, Object?>?;
      final npu = v['npu'] as Map<String, Object?>?;
      out
        ..writeln('const $name = LiteRtEmbedderVariant._(')
        ..writeln("  id: ${_str('$id/${v['slug']}')},")
        ..writeln('  modelId: ${_str(id)},')
        ..writeln('  model: ${_artifact(file)},');
      if (tokenizer != null) {
        out.writeln('  tokenizer: ${_artifact(tokenizer)},');
      }
      out..writeln('  ragProfileId: ${_str(v['rag_profile_id']! as String)},');
      if (v['image_rag_profile_id'] case final String image) {
        out.writeln('  imageRagProfileId: ${_str(image)},');
      }
      out
        ..writeln('  dimension: ${v['dimension']},')
        ..writeln('  maxInputTokens: ${v['max_input_tokens']},')
        ..writeln(
          '  modalities: {${modalities.map((x) => 'EmbeddingModality.$x').join(', ')}},',
        );
      if (npu != null) out.writeln('  npuTarget: ${_npuTarget(npu)},');
      out
        ..writeln(');')
        ..writeln();
    },
  );
}

/// The backends the loader lets the text model run on, from the file's
/// bytes: `_textBackendsAllowed` in litertlm_load_plan.dart, which the
/// package's catalog test checks this against. A file whose text model is
/// compiled for an NPU, or that carries a `tf_lite_aux` section, runs there
/// only; otherwise the text model's `backend_constraint`, else the GPU and
/// the CPU.
List<String> _textBackends(
  Map<String, Object?>? facts,
  Map<String, Object?> file,
) {
  if (facts == null) {
    throw StateError(
      '${file['path']} (${file['sha256']}) has no derived facts; run '
      'inspect_bundle_test.dart',
    );
  }
  // Not a LiteRT-LM container (a web export): only the web engine opens it.
  if (facts['problem'] != null) return const ['gpu'];
  final sections = [
    for (final s in (facts['sections'] as List? ?? const []))
      s as Map<String, Object?>,
  ];
  Map<String, Object?>? section(String modelType) {
    for (final s in sections) {
      if (s['model_type'] == modelType) return s;
    }
    return null;
  }

  final text = section('tf_lite_prefill_decode');
  if (section('tf_lite_aux') != null || text?['npu_target'] != null) {
    return const ['npu'];
  }
  final declared = {
    for (final b in (text?['backend_constraint'] as List? ?? const []))
      if (b == 'cpu' || b == 'gpu') b as String,
  };
  if (declared.isEmpty) return const ['gpu', 'cpu'];
  return [
    for (final b in const ['gpu', 'cpu'])
      if (declared.contains(b)) b,
  ];
}

const _stampVendor = {
  'qualcomm': 'Qualcomm',
  'google-tensor': 'Google',
  'mediatek': 'MediaTek',
  'intel': 'IntelOpenVINO',
};

String _npuTarget(Map<String, Object?> npu) =>
    'LiteRtLmNpuTarget(vendor: ${_str(_stampVendor[npu['vendor']]!)}, '
    'soc: ${_str(npu['soc']! as String)})';

String _artifact(Map<String, Object?> a) {
  final gated = a['gated'] != null;
  return 'ModelArtifact('
      'repo: ${_str(a['repo']! as String)}, '
      'revision: ${_str(a['revision']! as String)}, '
      'path: ${_str(a['path']! as String)}, '
      'sha256: ${_str(a['sha256']! as String)}, '
      'sizeBytes: ${a['size']}, '
      'installFilename: ${_str(a['install_filename']! as String)}'
      '${gated ? ', gated: true' : ''})';
}

String _str(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

String _size(int bytes) => bytes >= 1000 * 1000 * 1000
    ? '${(bytes / 1e9).toStringAsFixed(2)} GB'
    : '${(bytes / 1e6).round()} MB';

/// [content] formatted as `dart format` formats the packages (language
/// version 3.12, the workspace's floor).
Future<String> formatDart(String content) async {
  final dir = await Directory.systemTemp.createTemp('model_registry_format');
  try {
    final file = File(p.join(dir.path, 'generated.dart'))
      ..writeAsStringSync(content);
    final result = await Process.run('dart', [
      'format',
      '--language-version=3.12',
      '--output=show',
      '--summary=none',
      file.path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('dart format failed: ${result.stderr}');
    }
    return result.stdout as String;
  } finally {
    dir.deleteSync(recursive: true);
  }
}
