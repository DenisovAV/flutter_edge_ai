import 'dart:typed_data';

import 'package:flutter/widgets.dart' show ImageProvider;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show PreferredBackend;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import '../image_search/photo_preparation.dart';
import 'multimodal_rag_index.dart';
import 'multimodal_rag_item.dart';

/// The active embedding model, as the Embedding Models list left it.
final class MultimodalRagEmbedderInfo {
  const MultimodalRagEmbedderInfo({
    required this.name,
    required this.textProfileId,
    required this.kinds,
    this.backend,
  });

  final String name;

  /// Its catalog TEXT profile id; image and audio indexes derive theirs.
  final String textProfileId;

  /// What it can index on this platform: notes always, photos with a vision
  /// encoder, voice memos with an audio encoder (not on the web).
  final Set<MultimodalRagKind> kinds;

  /// npu for a per-SoC bundle, null (CPU natively) for every other.
  final PreferredBackend? backend;

  /// Whether it embeds audio here: voice memos, and Live's meeting windows.
  bool get embedsAudio => kinds.contains(MultimodalRagKind.memo);
}

/// The active language model, as the Inference Models list left it.
final class MultimodalRagLlmInfo {
  const MultimodalRagLlmInfo({
    required this.name,
    required this.seesImages,
    required this.hearsAudio,
  });

  final String name;

  /// Whether a retrieved photo is sent along with the question.
  final bool seesImages;

  /// Whether it takes audio: a retrieved memo is played to it, and Live
  /// sends it the meeting.
  final bool hearsAudio;
}

/// What is installed and active. A null part is missing: the screen says
/// which model list installs it.
final class MultimodalRagSetup {
  const MultimodalRagSetup({
    this.embedder,
    this.embedderProblem,
    this.llm,
    required this.audioSupported,
    this.preloadLlm = true,
  });

  final MultimodalRagEmbedderInfo? embedder;

  /// Why there is no usable embedder, ready to show; null when there is one.
  final String? embedderProblem;
  final MultimodalRagLlmInfo? llm;

  /// Whether this platform records and plays audio (not the web).
  final bool audioSupported;

  /// Whether the language model may load in the background while the user
  /// searches: not on the web, where it and the vision encoder take turns.
  final bool preloadLlm;

  /// Whether Live can run: the embedder embeds audio and the language model
  /// hears it.
  bool get liveSupported =>
      audioSupported &&
      (embedder?.embedsAudio ?? false) &&
      (llm?.hearsAudio ?? false);
}

/// The language model behind Ask and Live. Calls are serialized by the view
/// model: one session at a time.
abstract interface class MultimodalRagAnswerer {
  /// Loads the active language model unless it is loaded; returns what it
  /// runs on, e.g. "gpu".
  Future<String> warmUp();

  /// Streams the reply to [prompt], with [images] and [audio] (encoded WAV)
  /// when sent. A fresh session per call, closed when the stream ends.
  Stream<String> answer({
    required String systemInstruction,
    required String prompt,
    List<Uint8List> images = const [],
    Uint8List? audio,
    int maxOutputTokens = 220,
  });

  /// Stops the reply being generated.
  Future<void> stop();
}

/// Plays voice memos and the sample meeting.
abstract interface class MultimodalRagMemoPlayer {
  /// Plays [reference]; completes when it has finished or was stopped.
  Future<void> play(String reference);

  Future<void> stop();

  Future<void> dispose();
}

/// Records voice memos: 16 kHz mono WAV.
abstract interface class MultimodalRagRecorder {
  /// Starts recording; throws [MultimodalRagRecorderException] when the
  /// microphone is not available or not allowed.
  Future<void> start();

  /// Stops and returns the WAV bytes.
  Future<Uint8List> stop();

  Future<void> cancel();

  Future<void> dispose();
}

final class MultimodalRagRecorderException implements Exception {
  const MultimodalRagRecorderException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where photos and memos live: bundled assets (`asset:` references) and
/// copies the app kept.
abstract interface class MultimodalRagMedia {
  /// The encoded bytes [reference] points to.
  Future<Uint8List> read(String reference);

  /// What a photo reference shows.
  ImageProvider imageFor(String reference);

  /// Keeps a picked photo; returns its reference.
  Future<String> keepPhoto(Uint8List bytes, {required String name});

  /// Keeps a recorded memo (WAV); returns its reference.
  Future<String> keepMemo(Uint8List wav);

  /// Deletes a copy the app kept (never an asset).
  Future<void> forget(String reference);
}

/// Saves the library (user items, what is indexed).
abstract interface class MultimodalRagLibraryStore {
  Future<String?> read();
  Future<void> write(String json);
}

/// Everything the Multimodal RAG screen needs from outside. The app's wiring is
/// `multimodalRagAppDependencies()`; tests pass fakes.
final class MultimodalRagDependencies {
  const MultimodalRagDependencies({
    required this.readSetup,
    required this.embedderFor,
    required this.openIndex,
    required this.openMeetingIndex,
    required this.library,
    required this.media,
    required this.answerer,
    required this.player,
    required this.recorder,
    required this.microphone,
    required this.pickPhoto,
    this.preparePhoto = preparePhotoForEmbedding,
    this.beforeEmbedding = _released,
    this.beforeAnswer = _nothing,
    this.now = DateTime.now,
  });

  /// What is installed and active on the model lists.
  final Future<MultimodalRagSetup> Function() readSetup;

  /// The RAG adapter over the active embedder for one kind's index.
  final RagEmbedder Function(
    MultimodalRagKind kind,
    MultimodalRagEmbedderInfo info,
  )
  embedderFor;

  /// Opens one kind's index for the active embedder.
  final Future<RagIndex> Function(
    MultimodalRagKind kind,
    RagEmbedder embedder,
    MultimodalRagEmbedderInfo info,
  )
  openIndex;

  /// Opens Live's meeting index (audio windows) for the active embedder.
  final Future<RagIndex> Function(MultimodalRagEmbedderInfo info)
  openMeetingIndex;

  final MultimodalRagLibraryStore library;
  final MultimodalRagMedia media;
  final MultimodalRagAnswerer answerer;
  final MultimodalRagMemoPlayer player;
  final MultimodalRagRecorder recorder;

  /// The microphone as 16 kHz mono PCM16 chunks; cancelling the
  /// subscription stops it. Errors as [MultimodalRagRecorderException].
  final Stream<Uint8List> Function() microphone;

  /// A photo from the library; null when the user cancelled.
  final Future<({String name, Uint8List bytes})?> Function() pickPhoto;

  /// Upright, at most 1024 px, as a BMP (what the models get).
  final Future<PreparedPhoto> Function(Uint8List encoded) preparePhoto;

  /// Runs before anything is embedded, and before Ask: on the web, where
  /// the vision encoder and the language model do not fit in one page's
  /// WebAssembly memory, this releases the language model. True when it
  /// did (the next question loads it again).
  final Future<bool> Function() beforeEmbedding;

  /// Runs before the language model loads: on the web it releases the
  /// embedder's vision encoder.
  final Future<void> Function() beforeAnswer;

  final DateTime Function() now;

  /// Opens the knowledge index for [info]'s kinds.
  Future<MultimodalRagIndex> openMultimodalRagIndex(
    MultimodalRagEmbedderInfo info,
  ) => MultimodalRagIndex.open(
    kinds: info.kinds,
    embedderFor: (kind) => embedderFor(kind, info),
    openIndex: (kind, embedder) => openIndex(kind, embedder, info),
  );
}

Future<void> _nothing() async {}

Future<bool> _released() async => false;
