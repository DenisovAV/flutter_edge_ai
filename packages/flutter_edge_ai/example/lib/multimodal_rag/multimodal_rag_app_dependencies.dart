import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show ImageProvider;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gemma_bootstrap.dart' show exampleRag;
import '../image_search/photo_store.dart';
import '../models/embedding_model.dart' as catalog;
import '../rag_demo/rag_storage_location.dart';
import '../utils/installed_model_lookup.dart';
import 'multimodal_rag_dependencies.dart';
import 'multimodal_rag_item.dart';
import 'multimodal_rag_platform.dart';

/// The SharedPreferences key the library is saved under.
const kMultimodalRagLibraryKey = 'knowledge_library_v1';

/// For a language model outside the catalog — the SM8850 build of Gemma 4
/// for the Hexagon NPU, say — what it runs on (`npu`, `gpu` or `cpu`) and its
/// context window (an NPU bundle has one compiled size, and it is not
/// raised: pass that size). Applied to a catalog model too, when set.
const _llmBackendDefine = String.fromEnvironment('MULTIMODAL_RAG_LLM_BACKEND');
const _llmMaxTokensDefine = int.fromEnvironment(
  'MULTIMODAL_RAG_LLM_MAX_TOKENS',
);

/// Where the language model's vision and audio encoders run (`npu`, `gpu` or
/// `cpu`; unset leaves the package default, the CPU). Google's Gemma 4 E2B
/// builds that compile every modality for the Hexagon NPU need `npu` here.
const _llmEncodersDefine = String.fromEnvironment(
  'MULTIMODAL_RAG_LLM_ENCODERS',
);

/// The name shown for a language model outside the catalog (else its file).
const _llmNameDefine = String.fromEnvironment('MULTIMODAL_RAG_LLM_NAME');

PreferredBackend? _backendNamed(String name) => switch (name) {
  'npu' => PreferredBackend.npu,
  'gpu' => PreferredBackend.gpu,
  'cpu' => PreferredBackend.cpu,
  _ => null,
};

/// The app's wiring of the Multimodal RAG screen: the models the three model
/// lists left active, SQLite indexes (one location per kind and embedding
/// space), photos and memos kept in the app's documents (photos in OPFS on
/// the web), `just_audio` playback and `record` capture.
MultimodalRagDependencies multimodalRagAppDependencies() {
  final photos = createPhotoStore(directoryName: 'knowledge_photos');
  final picker = ImagePicker();
  RagEmbedder embedder(String profileId, MultimodalRagEmbedderInfo info) =>
      FlutterEdgeAiActiveEmbedder(
        profileId: profileId,
        preferredBackend: info.backend,
        // Every index declares every medium the screen uses, so core loads
        // the embedder once with all of them instead of once per index.
        supportImage: info.kinds.contains(MultimodalRagKind.photo),
        supportAudio: info.embedsAudio,
      );
  return MultimodalRagDependencies(
    readSetup: readMultimodalRagSetup,
    embedderFor: (kind, info) =>
        embedder(multimodalRagProfileId(kind, info), info),
    openIndex: (kind, embedder, info) async {
      final location = await resolveRagStorageLocation(
        'knowledge_${kind.modality.name}_${multimodalRagProfileId(kind, info)}.db',
      );
      return exampleRag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: location,
          documents: kind.modality,
        ),
        embedder: embedder,
      );
    },
    // Live's windows: audio documents in the text id's space, like memos,
    // at a location of their own.
    openMeetingIndex: (info) async => exampleRag.open(
      spec: VectorStoreSpec(
        providerId: SqliteVectorStoreProvider.providerId,
        location: await resolveRagStorageLocation(
          'knowledge_meeting_${info.textProfileId}.db',
        ),
        documents: EmbeddingModality.audio,
      ),
      embedder: embedder(info.textProfileId, info),
    ),
    library: const _PreferencesLibraryStore(),
    media: _AppMedia(photos),
    answerer: _LlmAnswerer(),
    player: _JustAudioPlayer(),
    recorder: _Recorder(),
    microphone: _microphone,
    pickPhoto: () async {
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null) return null;
      return (name: file.name, bytes: await file.readAsBytes());
    },
    beforeEmbedding: kIsWeb ? _releaseLanguageModel : () async => false,
    beforeAnswer: kIsWeb ? _releaseVisionEncoder : () async {},
  );
}

/// The profile of [kind]'s index: the text id for notes and memos (audio
/// vectors do not depend on the vision budget, and the store's modality
/// keeps an audio index apart from a text one), the image id — the text id
/// plus the vision budget — for photos.
String multimodalRagProfileId(
  MultimodalRagKind kind,
  MultimodalRagEmbedderInfo info,
) => switch (kind) {
  MultimodalRagKind.photo => catalog.imageIndexProfileId(info.textProfileId),
  MultimodalRagKind.note || MultimodalRagKind.memo => info.textProfileId,
};

/// What the three model lists left active.
Future<MultimodalRagSetup> readMultimodalRagSetup() async {
  const audioSupported = !kIsWeb;
  final (embedder, problem) = await _embedder(audioSupported: audioSupported);
  return MultimodalRagSetup(
    embedder: embedder,
    embedderProblem: problem,
    llm: _llm()?.info,
    audioSupported: audioSupported,
    preloadLlm: !kIsWeb,
  );
}

Future<(MultimodalRagEmbedderInfo?, String?)> _embedder({
  required bool audioSupported,
}) async {
  const install =
      'Install EmbeddingGemma 2 Text + Vision + Audio (740M) from the '
      'Embedding Models list.';
  final spec = FlutterEdgeAi.activeEmbedderSpec;
  if (spec == null) return (null, 'No embedding model is active. $install');
  final profileId = await activeEmbeddingProfileId();
  final files = {for (final file in spec.files) file.filename};
  final model = catalog.EmbeddingModel.values
      .where((m) => m.ragProfileId == profileId && files.contains(m.filename))
      .firstOrNull;
  if (profileId == null || model == null) {
    return (
      null,
      'The active embedding model is not one of the example\'s, so its '
          'embedding space has no name. $install',
    );
  }
  return (
    MultimodalRagEmbedderInfo(
      // "EmbeddingGemma 2 (740M)": the card lists what it embeds.
      name: model.displayName.replaceFirst(
        RegExp(r' Text( \+ Vision)?( \+ Audio)?'),
        '',
      ),
      textProfileId: model.ragProfileId,
      kinds: {
        MultimodalRagKind.note,
        if (model.embedsImages) MultimodalRagKind.photo,
        if (model.embedsAudio && audioSupported) MultimodalRagKind.memo,
      },
      backend: model.embedderBackend,
    ),
    null,
  );
}

/// The active language model and how the screen loads it: the catalog's
/// context window and backend for a catalog model, or the
/// MULTIMODAL_RAG_LLM_BACKEND / MULTIMODAL_RAG_LLM_MAX_TOKENS defines.
({
  MultimodalRagLlmInfo info,
  int maxTokens,
  PreferredBackend? backend,
  bool supportImage,
  bool supportAudio,
})?
_llm() {
  final spec = FlutterEdgeAi.activeModelSpec;
  if (spec == null) return null;
  final id = activeInferenceModelId();
  final model = switch (id == null ? null : resolveCatalog(id)) {
    InferenceMatch(:final model) => model,
    _ => null,
  };
  final gemma4 = spec.modelType == ModelType.gemma4 && !kIsWeb;
  final supportImage = model?.supportImage ?? gemma4;
  final supportAudio = model?.supportAudio ?? gemma4;
  return (
    info: MultimodalRagLlmInfo(
      name:
          model?.displayName ??
          (_llmNameDefine.isEmpty ? null : _llmNameDefine) ??
          id ??
          spec.name,
      seesImages: supportImage,
      hearsAudio: supportAudio,
    ),
    maxTokens: _llmMaxTokensDefine > 0
        ? _llmMaxTokensDefine
        : model?.maxTokens ?? 4096,
    backend: switch (_llmBackendDefine) {
      'npu' => PreferredBackend.npu,
      'gpu' => PreferredBackend.gpu,
      'cpu' => PreferredBackend.cpu,
      _ => model?.preferredBackend,
    },
    supportImage: supportImage,
    supportAudio: supportAudio,
  );
}

/// The microphone as 16 kHz mono PCM16 chunks, while listened to.
Stream<Uint8List> _microphone() {
  final recorder = AudioRecorder();
  StreamSubscription<Uint8List>? audio;
  late final StreamController<Uint8List> controller;
  controller = StreamController<Uint8List>(
    onListen: () async {
      try {
        if (!await recorder.hasPermission()) {
          throw const MultimodalRagRecorderException(
            'Live needs the microphone: allow it in Settings.',
          );
        }
        final stream = await recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
            echoCancel: true,
            noiseSuppress: true,
          ),
        );
        audio = stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      } catch (e, st) {
        controller.addError(e, st);
        await controller.close();
      }
    },
    onCancel: () async {
      await audio?.cancel();
      await recorder.stop();
      await recorder.dispose();
    },
  );
  return controller.stream;
}

/// The web: the embedder's vision encoder (about 3.3 GB) and a `.litertlm`
/// language model do not share the page's 4 GB of WebAssembly memory, so
/// they take turns. True when the language model was released.
Future<bool> _releaseLanguageModel() async {
  final model = FlutterEdgeAiPlugin.instance.initializedModel;
  if (model == null || model.isClosed) return false;
  debugPrint('[Multimodal RAG] web: releasing the language model to embed');
  await model.close();
  return true;
}

Future<void> _releaseVisionEncoder() async {
  final embedder = FlutterEdgeAiPlugin.instance.initializedEmbeddingModel;
  if (embedder == null || embedder.isClosed) return;
  if (!embedder.modalities.contains(EmbeddingModality.image)) return;
  debugPrint('[Multimodal RAG] web: releasing the vision encoder for the LLM');
  await embedder.close();
}

final class _PreferencesLibraryStore implements MultimodalRagLibraryStore {
  const _PreferencesLibraryStore();

  @override
  Future<String?> read() async => (await SharedPreferences.getInstance())
      .getString(kMultimodalRagLibraryKey);

  @override
  Future<void> write(String json) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      kMultimodalRagLibraryKey,
      json,
    );
    if (!saved) throw StateError('Could not save the knowledge library.');
  }
}

final class _AppMedia implements MultimodalRagMedia {
  _AppMedia(this._photos);

  final PhotoStore _photos;

  @override
  Future<Uint8List> read(String reference) async {
    if (assetKeyOf(reference) case final key?) {
      final data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    if (reference.endsWith('.wav')) return readMemoFile(reference);
    return _photos.read(reference);
  }

  @override
  ImageProvider imageFor(String reference) => _photos.imageFor(reference);

  @override
  Future<String> keepPhoto(Uint8List bytes, {required String name}) =>
      _photos.keep(bytes, name: name);

  @override
  Future<String> keepMemo(Uint8List wav) => keepMemoFile(wav);

  @override
  Future<void> forget(String reference) async {
    if (assetKeyOf(reference) != null) return;
    if (reference.endsWith('.wav')) return forgetMemoFile(reference);
    await _photos.forget(reference);
  }
}

/// The active language model. It stays loaded (it is the app's singleton);
/// each answer runs in a fresh session that is closed when it ends.
final class _LlmAnswerer implements MultimodalRagAnswerer {
  InferenceModelSession? _session;

  /// What the model is asked to run on: the catalog's backend, CPU on the
  /// iOS Simulator (it has no GPU for LiteRT-LM).
  Future<PreferredBackend?> _backend() async =>
      await isIosSimulator() ? PreferredBackend.cpu : _llm()?.backend;

  Future<InferenceModel> _model() async {
    final llm = _llm();
    if (llm == null) throw StateError('No language model is active.');
    return FlutterEdgeAi.getActiveModel(
      maxTokens: llm.maxTokens,
      preferredBackend: await _backend(),
      supportImage: llm.supportImage,
      supportAudio: llm.supportAudio,
      maxNumImages: llm.supportImage ? 1 : null,
      preferredVisionBackend: _backendNamed(_llmEncodersDefine),
      preferredAudioBackend: _backendNamed(_llmEncodersDefine),
    );
  }

  @override
  Future<String> warmUp() async {
    final model = await _model();
    final backend = model.activeBackend?.name ?? 'webgpu';
    debugPrint(
      '[Multimodal RAG] language model on $backend (asked for '
      '${(await _backend())?.name ?? 'the default'})',
    );
    return backend;
  }

  @override
  Stream<String> answer({
    required String systemInstruction,
    required String prompt,
    List<Uint8List> images = const [],
    Uint8List? audio,
    int maxOutputTokens = 220,
  }) async* {
    final model = await _model();
    final session = await model.createSession(
      systemInstruction: systemInstruction,
      enableVisionModality: images.isNotEmpty,
      enableAudioModality: audio != null,
      maxOutputTokens: maxOutputTokens,
      // Low: answers read figures and dates off the sources.
      temperature: 0.2,
    );
    _session = session;
    try {
      await session.addQueryChunk(
        Message(
          text: prompt,
          isUser: true,
          imageBytes: images.firstOrNull,
          images: images.length > 1 ? images : const [],
          audioBytes: audio,
        ),
      );
      yield* session.getResponseAsync();
    } finally {
      _session = null;
      await session.close();
    }
  }

  @override
  Future<void> stop() async => _session?.stopGeneration();
}

final class _JustAudioPlayer implements MultimodalRagMemoPlayer {
  final _player = AudioPlayer();

  /// Bumped by every play and stop: a play that was overtaken leaves the
  /// player to the one that overtook it.
  int _generation = 0;

  @override
  Future<void> play(String reference) async {
    final generation = ++_generation;
    if (assetKeyOf(reference) case final key?) {
      await _player.setAsset(key);
    } else {
      await _player.setFilePath(reference);
    }
    if (generation != _generation) return;
    // Completes when the memo has played to its end or was stopped.
    await _player.play();
    if (generation == _generation) await _player.stop();
  }

  @override
  Future<void> stop() {
    _generation++;
    return _player.stop();
  }

  @override
  Future<void> dispose() => _player.dispose();
}

final class _Recorder implements MultimodalRagRecorder {
  final _recorder = AudioRecorder();

  @override
  Future<void> start() async {
    // Asks for the microphone where the platform asks (Android, iOS, macOS).
    if (!await _recorder.hasPermission()) {
      throw const MultimodalRagRecorderException(
        'Recording a memo needs the microphone: allow it in Settings.',
      );
    }
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: await temporaryRecordingPath(),
    );
  }

  @override
  Future<Uint8List> stop() async {
    final path = await _recorder.stop();
    if (path == null) throw StateError('The recorder returned no file.');
    return readAndDeleteRecording(path);
  }

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}
