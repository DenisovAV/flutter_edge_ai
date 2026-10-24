// Fakes for the Multimodal RAG screen's tests: a topic embedder, in-memory vector
// stores behind the REAL flutter_edge_ai_rag (RagIndex, bindings, and
// FlutterEdgeAiActiveEmbedder's role policy), and a scripted language model,
// player, recorder, microphone and media. Audio carries its topic in its
// samples (see [topicPcm]), so a memo, a spoken question and a meeting window
// are found by what they are "about" — nothing is transcribed. The real
// models run in integration_test/multimodal_rag_demo_test.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_dependencies.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_item.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_prompt.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_seed.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_view_model.dart';
import 'package:flutter_edge_ai_example/utils/audio_converter.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

const kTestTextProfile = 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1';

/// What the fake embedder tells apart: one axis each.
const kTopics = [
  'flight',
  'taxi',
  'kitchen',
  'chart',
  'basil',
  'dentist',
  'sunday',
  'pasta',
  'retreat',
  'tires',
];

/// The topic of each sample item.
const kItemTopics = {
  'note-london': 'flight',
  'note-kitchen': 'kitchen',
  'note-q3': 'chart',
  'note-pasta': 'pasta',
  'note-car': 'tires',
  'photo-0412': 'taxi',
  'photo-0291': 'chart',
  'photo-0290': 'chart',
  'memo-kitchen': 'kitchen',
  'memo-flight': 'flight',
  'memo-groceries': 'basil',
  'memo-offsite': 'retreat',
  'memo-mom': 'sunday',
  'memo-dentist': 'dentist',
};

/// 16 kHz mono PCM16 whose every sample says its [topic] (null: none of
/// them): loud enough to be speech to Live's windower.
Uint8List topicPcm(String? topic, Duration length) {
  final value = topic == null ? 900 : 1000 + 100 * kTopics.indexOf(topic);
  final samples = length.inMicroseconds * 16 ~/ 1000;
  final bytes = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    bytes.setInt16(i * 2, value, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// [ms] of silence.
Uint8List silencePcm(int ms) => Uint8List(ms * 32);

Uint8List topicWav(String? topic, Duration length) =>
    AudioConverter.pcmToWav(topicPcm(topic, length));

/// The topic [pcm] carries: its first sound.
String? topicOfPcm(Uint8List pcm) {
  final view = ByteData.sublistView(pcm);
  for (var i = 0; i + 1 < pcm.length; i += 2) {
    final value = view.getInt16(i, Endian.little);
    if (value == 0) continue;
    final axis = (value - 1000) ~/ 100;
    return value >= 1000 && axis < kTopics.length ? kTopics[axis] : null;
  }
  return null;
}

/// Sample memo [index] as a WAV that carries its topic.
Uint8List memoWav(int index) => topicWav(
  kItemTopics[kSeedMemos[index].id],
  Duration(milliseconds: 600 + 100 * index),
);

/// The bundled spoken question: about the taxi.
final kQuestionWav = topicWav('taxi', const Duration(milliseconds: 1500));

/// The bundled meeting: small talk, then the dentist, then the taxi.
final kMeetingPcm = Uint8List.fromList([
  ...topicPcm(null, const Duration(seconds: 2)),
  ...silencePcm(400),
  ...topicPcm('dentist', const Duration(seconds: 2)),
  ...silencePcm(400),
  ...topicPcm('taxi', const Duration(seconds: 2)),
  ...silencePcm(400),
]);

/// Embeds by topic: a vector with 1 on the topic's axis and 0.1 elsewhere.
/// Text finds its topic by the words in it; images and audio carry their
/// item id (see [FakeMedia]).
final class TopicEmbedder extends EmbeddingModel {
  TopicEmbedder({this.audio = true, this.images = true});

  final bool audio;
  final bool images;
  final tasks = <TaskType>[];
  final embedded = <String>[];
  bool _closed = false;

  /// Sent instead of a vector for an image whose item id is listed.
  final Map<String, Object> failures = {};

  @override
  int get dimension => kTopics.length + 1;

  @override
  Set<EmbeddingModality> get modalities => {
    EmbeddingModality.text,
    if (images) EmbeddingModality.image,
    if (audio) EmbeddingModality.audio,
  };

  @override
  PreferredBackend? get activeBackend => PreferredBackend.cpu;

  @override
  bool get isClosed => _closed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async {
    tasks.add(taskType);
    String? topic;
    if (input.text case final text?) {
      final lower = text.toLowerCase();
      topic = kTopics.where(lower.contains).firstOrNull;
      embedded.add('text');
    } else if (input.images.isNotEmpty) {
      final id = utf8.decode(input.images.single);
      if (failures[id] case final failure?) throw failure;
      topic = kItemTopics[id];
      embedded.add(id);
    } else if (input.audio case final audio?) {
      topic = topicOfPcm(AudioConverter.parseWav(audio).pcmData);
      embedded.add('audio:$topic');
    }
    final axis = topic == null ? kTopics.length : kTopics.indexOf(topic);
    final vector = [for (var i = 0; i < dimension; i++) i == axis ? 1.0 : 0.1];
    final norm = math.sqrt(vector.fold(0.0, (s, v) => s + v * v));
    return [for (final v in vector) v / norm];
  }

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async => _closed = true;
}

/// One in-memory store per location.
final class MemoryProvider implements VectorStoreProvider {
  final stores = <String, MemoryStore>{};

  @override
  String get id => 'memory';

  @override
  String get name => 'memory';

  @override
  int get priority => 0;

  @override
  bool canHandle(VectorStoreSpec spec) => spec.providerId == id;

  @override
  Future<VectorStoreRepository> createStore(VectorStoreSpec spec) async =>
      stores.putIfAbsent(spec.location, MemoryStore.new);
}

/// A vector store in memory, ranking by cosine similarity.
final class MemoryStore extends VectorStoreRepository {
  VectorStoreBinding? binding;
  final documents = <String, (String, List<double>)>{};

  @override
  bool isInitialized = false;

  @override
  FilterSchema filterSchema = FilterSchema.empty;

  @override
  void configure(FilterSchema schema) => filterSchema = schema;

  @override
  Future<void> initialize(String location) async => isInitialized = true;

  @override
  Future<VectorStoreBinding?> readBinding() async => binding;

  @override
  Future<void> bind(VectorStoreBinding binding) async {
    final existing = this.binding;
    if (existing != null && existing != binding) {
      throw VectorStoreException('already bound to $existing');
    }
    this.binding = binding;
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async => documents[id] = (content, embedding);

  @override
  Future<void> removeDocument({required String id}) async =>
      documents.remove(id);

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    double dot(List<double> a) => [
      for (var i = 0; i < a.length; i++) a[i] * queryEmbedding[i],
    ].fold(0.0, (s, v) => s + v);
    final hits = [
      for (final MapEntry(key: id, value: (content, vector))
          in documents.entries)
        RetrievalResult(id: id, content: content, similarity: dot(vector)),
    ]..sort((a, b) => b.similarity.compareTo(a.similarity));
    return hits.take(topK).toList();
  }

  @override
  Future<VectorStoreStats> getStats() async => VectorStoreStats(
    documentCount: documents.length,
    vectorDimension: binding?.profile.dimension ?? 0,
  );

  @override
  Future<void> clear() async => documents.clear();

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async => isInitialized = false;
}

/// Media: a photo's bytes are its item id; a memo is a [memoWav]; the
/// sample meeting and spoken question are [kMeetingPcm] and [kQuestionWav].
final class FakeMedia implements MultimodalRagMedia {
  final kept = <String, Uint8List>{};
  final forgotten = <String>[];
  int _n = 0;

  /// Reference → item id, for photos and memos the test added.
  final ids = <String, String>{};

  @override
  Future<Uint8List> read(String reference) async {
    if (kept[reference] case final bytes?) return bytes;
    if (reference == kSampleMeeting) {
      return AudioConverter.pcmToWav(kMeetingPcm);
    }
    if (reference == kSampleQuestion) return kQuestionWav;
    for (final photo in kSeedPhotos) {
      if (reference.endsWith(photo.asset)) {
        return Uint8List.fromList(utf8.encode(photo.id));
      }
    }
    for (final (i, memo) in kSeedMemos.indexed) {
      if (reference.endsWith(memo.asset)) return memoWav(i);
    }
    throw StateError('no media at $reference');
  }

  @override
  ImageProvider imageFor(String reference) =>
      MemoryImage(Uint8List.fromList(_png));

  @override
  Future<String> keepPhoto(Uint8List bytes, {required String name}) async {
    final reference = '/kept/photo-${_n++}-$name';
    kept[reference] = bytes;
    return reference;
  }

  @override
  Future<String> keepMemo(Uint8List wav) async {
    final reference = '/kept/memo-${_n++}.wav';
    kept[reference] = wav;
    return reference;
  }

  @override
  Future<void> forget(String reference) async {
    forgotten.add(reference);
    kept.remove(reference);
  }
}

/// A 1x1 transparent PNG.
const _png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

final class MemoryLibraryStore implements MultimodalRagLibraryStore {
  String? saved;
  int writes = 0;

  @override
  Future<String?> read() async => saved;

  @override
  Future<void> write(String json) async {
    writes++;
    saved = json;
  }
}

/// A language model that streams [reply] in words, and in Live answers the
/// listening prompt with [hear].
final class FakeAnswerer implements MultimodalRagAnswerer {
  String reply =
      'The total was 26.50 [1]. Finance pays airport rides back up to 40 '
      'pounds [2].';

  /// Live's reply for a window: a question when it is about the taxi.
  String Function(Uint8List audio) hear = (audio) =>
      topicOfPcm(AudioConverter.parseWav(audio).pcmData) == 'taxi'
      ? 'QUESTION: How much was the airport taxi?'
      : 'NONE';

  final prompts = <String>[];
  final systems = <String>[];
  final images = <List<Uint8List>>[];
  final audios = <Uint8List?>[];
  int heard = 0;
  int warmUps = 0;
  bool stopped = false;

  /// When set, an answer waits for it before streaming.
  Completer<void>? gate;

  @override
  Future<String> warmUp() async {
    warmUps++;
    return 'cpu';
  }

  @override
  Stream<String> answer({
    required String systemInstruction,
    required String prompt,
    List<Uint8List> images = const [],
    Uint8List? audio,
    int maxOutputTokens = 220,
  }) async* {
    if (systemInstruction == kLiveListenInstruction) {
      heard++;
      yield hear(audio!);
      return;
    }
    systems.add(systemInstruction);
    prompts.add(prompt);
    this.images.add(images);
    audios.add(audio);
    stopped = false;
    await gate?.future;
    for (final word in reply.split(' ')) {
      if (stopped) return;
      yield '$word ';
    }
  }

  @override
  Future<void> stop() async => stopped = true;
}

final class FakePlayer implements MultimodalRagMemoPlayer {
  final played = <String>[];
  Completer<void>? _playing;

  @override
  Future<void> play(String reference) {
    played.add(reference);
    return (_playing = Completer<void>()).future;
  }

  /// Ends the memo playing.
  void finish() => _playing?.complete();

  @override
  Future<void> stop() async {
    final playing = _playing;
    _playing = null;
    if (playing != null && !playing.isCompleted) playing.complete();
  }

  @override
  Future<void> dispose() async {}
}

final class FakeRecorder implements MultimodalRagRecorder {
  Object? startError;
  bool started = false;
  bool cancelled = false;

  /// What [stop] returns: by default a memo about basil.
  Uint8List recording = topicWav('basil', const Duration(seconds: 1));

  @override
  Future<void> start() async {
    if (startError case final error?) throw error;
    started = true;
  }

  @override
  Future<Uint8List> stop() async {
    started = false;
    return recording;
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async {}
}

/// Everything wired: [MultimodalRagDependencies] over the fakes.
final class MultimodalRagRig {
  MultimodalRagRig({
    TopicEmbedder? embedder,
    this.withLlm = true,
    this.withEmbedder = true,
  }) : embedder = embedder ?? TopicEmbedder();

  final TopicEmbedder embedder;
  bool withLlm;
  bool withEmbedder;
  final provider = MemoryProvider();
  final media = FakeMedia();
  final library = MemoryLibraryStore();
  final answerer = FakeAnswerer();
  final player = FakePlayer();
  final recorder = FakeRecorder();

  /// The microphone Live listens to: the test adds PCM chunks.
  StreamController<Uint8List>? microphone;
  int microphoneStarts = 0;
  int beforeEmbedding = 0;
  int beforeAnswer = 0;
  bool releaseLlmOnEmbedding = false;
  ({String name, Uint8List bytes})? pickedPhoto;

  /// The clock the sample meeting is fed by; tests pass the fake one.
  DateTime Function() now = DateTime.now;
  Object? prepareError;

  late final _spec = EmbeddingModelSpec(
    name: 'eg2-740m',
    modelSource: ModelSource.file('/models/eg2-740m.litertlm'),
  );

  Set<MultimodalRagKind> get _kinds => {
    MultimodalRagKind.note,
    if (embedder.images) MultimodalRagKind.photo,
    if (embedder.audio) MultimodalRagKind.memo,
  };

  MultimodalRagDependencies dependencies() => MultimodalRagDependencies(
    readSetup: () async => MultimodalRagSetup(
      embedder: withEmbedder
          ? MultimodalRagEmbedderInfo(
              name: 'EmbeddingGemma 2 (740M)',
              textProfileId: kTestTextProfile,
              kinds: _kinds,
            )
          : null,
      embedderProblem: withEmbedder
          ? null
          : 'No embedding model is active. Install EmbeddingGemma 2.',
      llm: withLlm
          ? const MultimodalRagLlmInfo(
              name: 'Gemma 4 E2B IT',
              seesImages: true,
              hearsAudio: true,
            )
          : null,
      audioSupported: true,
    ),
    embedderFor: (kind, info) => FlutterEdgeAiActiveEmbedder(
      profileId: kind == MultimodalRagKind.photo
          ? '${info.textProfileId}-vis140'
          : info.textProfileId,
      supportImage: info.kinds.contains(MultimodalRagKind.photo),
      supportAudio: info.kinds.contains(MultimodalRagKind.memo),
      specResolver: () => _spec,
      modelResolver: () async => embedder,
    ),
    openIndex: (kind, embedder, info) =>
        FlutterEdgeAiRag(providers: [provider]).open(
          spec: VectorStoreSpec(
            providerId: 'memory',
            location: kind.name,
            documents: kind.modality,
          ),
          embedder: embedder,
        ),
    openMeetingIndex: (info) => FlutterEdgeAiRag(providers: [provider]).open(
      spec: VectorStoreSpec(
        providerId: 'memory',
        location: 'meeting',
        documents: EmbeddingModality.audio,
      ),
      embedder: FlutterEdgeAiActiveEmbedder(
        profileId: info.textProfileId,
        supportImage: info.kinds.contains(MultimodalRagKind.photo),
        supportAudio: true,
        specResolver: () => _spec,
        modelResolver: () async => embedder,
      ),
    ),
    library: library,
    media: media,
    answerer: answerer,
    player: player,
    recorder: recorder,
    microphone: () {
      microphoneStarts++;
      return (microphone = StreamController<Uint8List>()).stream;
    },
    pickPhoto: () async => pickedPhoto,
    preparePhoto: (bytes) async {
      if (prepareError case final error?) throw error;
      return (
        bytes: bytes,
        width: 640,
        height: 480,
        sourceWidth: 640,
        sourceHeight: 480,
      );
    },
    beforeEmbedding: () async {
      beforeEmbedding++;
      return releaseLlmOnEmbedding;
    },
    beforeAnswer: () async => beforeAnswer++,
    now: () => now(),
  );

  /// Documents in [kind]'s store.
  Map<String, (String, List<double>)> stored(MultimodalRagKind kind) =>
      provider.stores[kind.name]?.documents ?? const {};
}

/// Lets the fakes' futures and the screen's animations run.
Future<void> settle(WidgetTester tester, {int frames = 40}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}
