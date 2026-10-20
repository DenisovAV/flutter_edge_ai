// The identity of every model the example installs, as it is persisted or
// resolved today: the URL each platform downloads (the LLM's installed id is
// that URL's last segment), the file names an embedder and its tokenizer are
// stored under, the RAG profile ids an index is bound to, the model and file
// types the installers are given, and which per-SoC embedders each platform
// lists. Written to test/goldens/example_model_identity.json.
//
// The example's model lists are about to be generated from the model catalog
// (model_registry/). An installed model, a stored RAG index or a saved
// selection that silently changes identity strands what users already have,
// so the move must change nothing here except what it means to change, and
// every such change shows up as a diff of the golden in the same commit.
//
// Web is recorded as the declared webUrl only: kIsWeb is a constant false on
// the VM, so the web branch of `Model.url` cannot run here.
//
// To write it (never on CI):
//   cd packages/flutter_edge_ai/example
//   UPDATE_GOLDENS=1 flutter test test/example_model_identity_golden_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart';
import 'package:flutter_edge_ai_example/models/model.dart';
import 'package:flutter_edge_ai_example/models/stt_model.dart';
import 'package:flutter_edge_ai_example/models/translate_model.dart';
import 'package:flutter_edge_ai_example/models/tts_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _goldenPath = 'test/goldens/example_model_identity.json';

const _nativePlatforms = [
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
];

/// [read] evaluated with `defaultTargetPlatform` set to each native platform.
Map<String, Object?> _perPlatform(Object? Function() read) {
  final values = <String, Object?>{};
  try {
    for (final platform in _nativePlatforms) {
      debugDefaultTargetPlatformOverride = platform;
      values[platform.name] = read();
    }
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
  return values;
}

String _lastSegment(String url) => Uri.parse(url).pathSegments.last;

Map<String, Object?> _inference(Model m) => {
  'baseUrl': m.baseUrl,
  'webUrl': m.webUrl,
  'desktopUrl': m.desktopUrl,
  'hfRepo': m.hfRepo,
  'filename': m.filename,
  'localModel': m.localModel,
  'needsAuth': m.needsAuth,
  'modelType': m.modelType.name,
  'fileType': _perPlatform(() => m.fileType.name),
  'maxTokens': m.maxTokens,
  'url': _perPlatform(() => m.url),
  'installedId': _perPlatform(() => _lastSegment(m.url)),
  'preferredBackend': _perPlatform(() => m.preferredBackend.name),
};

Map<String, Object?> _embedding(EmbeddingModel m) => {
  'url': m.url,
  'filename': m.filename,
  'tokenizerUrl': m.tokenizerUrl,
  'tokenizerFilename': m.tokenizerFilename,
  'sourceType': m.sourceType.name,
  'sha256': m.sha256,
  'ragProfileId': m.ragProfileId,
  'imageRagProfileId': m.imageRagProfileId,
  'dimension': m.dimension,
  'maxSeqLen': m.maxSeqLen,
  'embedsImages': m.embedsImages,
  'embedsAudio': m.embedsAudio,
  'npuSoc': m.npuSoc,
  'npuVendor': m.npuVendor.name,
  'embedderBackend': m.embedderBackend?.name,
  'needsAuth': m.needsAuth,
  'listedOn': [
    for (final MapEntry(:key, :value) in _perPlatform(
      () => listedEmbeddingModels.contains(m),
    ).entries)
      if (value == true) key,
  ],
};

Map<String, Object?> _translate(TranslateModel m) => {
  'url': m.url,
  'installedId': _lastSegment(m.url),
  'filename': m.filename,
  'needsAuth': m.needsAuth,
  'modelType': m.modelType.name,
  'fileType': m.fileType.name,
  'preferredBackend': m.preferredBackend.name,
  'maxTokens': m.maxTokens,
};

Map<String, Object?> _stt(SttModel m) => {
  'modelUrl': m.modelUrl,
  'tokenizerUrl': m.tokenizerUrl,
  'sttModelType': m.sttModelType.name,
  'needsAuth': m.needsAuth,
  'isSupported': m.isSupported,
};

Map<String, Object?> _tts(TtsModel m) => {
  'baseUrl': m.baseUrl,
  'ttsModelType': m.ttsModelType.name,
  'isSupported': m.isSupported,
};

Map<String, Object?> exampleModelIdentity() => {
  'Model': {for (final m in Model.values) m.name: _inference(m)},
  'EmbeddingModel': {
    for (final m in EmbeddingModel.values) m.name: _embedding(m),
  },
  'TranslateModel': {
    for (final m in TranslateModel.values) m.name: _translate(m),
  },
  'SttModel': {for (final m in SttModel.values) m.name: _stt(m)},
  'TtsModel': {for (final m in TtsModel.values) m.name: _tts(m)},
};

void main() {
  test('every example model keeps its install identity', () {
    final actual =
        '${const JsonEncoder.withIndent('  ').convert(exampleModelIdentity())}\n';
    final golden = File(_goldenPath);
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync(actual);
      return;
    }
    expect(
      golden.existsSync(),
      isTrue,
      reason: '$_goldenPath is missing; write it with UPDATE_GOLDENS=1',
    );
    expect(
      actual,
      golden.readAsStringSync(),
      reason:
          'An example model changed identity. If that is intended, rewrite '
          'the golden with UPDATE_GOLDENS=1 and commit the diff with the '
          'change that causes it.',
    );
  });
}
