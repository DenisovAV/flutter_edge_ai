import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ImageProvider;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import '../image_search/photo_preparation.dart';
import '../image_search/photo_store.dart' show assetPhotoReference;
import '../utils/audio_converter.dart';
import 'multimodal_rag_audio.dart';
import 'multimodal_rag_dependencies.dart';
import 'multimodal_rag_index.dart';
import 'multimodal_rag_item.dart';
import 'multimodal_rag_library.dart';
import 'multimodal_rag_live.dart';
import 'multimodal_rag_prompt.dart';
import 'multimodal_rag_ranking.dart';

enum MultimodalRagStatus { loading, ready, failed }

/// Where the language model is.
enum LlmState { missing, idle, loading, ready, failed }

/// Where Live is.
enum LiveState { idle, listening, finished }

/// A search hit with its item.
typedef MultimodalRagResult = ({MultimodalRagItem item, RankedHit hit});

/// The longest memo recorded in the app: EmbeddingGemma 2 embeds about 40 s
/// of audio (1024 tokens at about 25 a second).
const kMaxMemo = Duration(seconds: 30);

/// How many retrieved items an answer is given.
const kAnswerSources = 4;

/// Search-as-you-type waits this long after the last keystroke.
const kTypingPause = Duration(milliseconds: 350);

/// The bundled two-voice meeting Live can play as if it were the microphone.
final kSampleMeeting = assetPhotoReference('assets/knowledge/meeting.wav');

/// The bundled spoken question "Ask by voice" plays as if it were the
/// microphone.
final kSampleQuestion = assetPhotoReference('assets/knowledge/question.wav');

/// How much of the meeting "Answer what was just said" hears.
const kJustSaid = Duration(seconds: 10);

/// Live surfacing, calibrated on the sample meeting with the 740M
/// (integration_test/multimodal_rag_live_calibration_test.dart): a window whose
/// sound is about an item lifts it 0.15–0.18 over the rest of its kind; the
/// windows about nothing in the library lift their best item at most 0.052.
/// A window's best match surfaces at this lift …
const kSurfaceLift = 0.09;

/// … when it beats the runner-up by this much.
const kSurfaceMargin = 0.02;

/// The runner-up surfaces with it at this lift, when it is another kind
/// (the Q3 chart next to the Q3 note: 0.120).
const kSurfaceSecondLift = 0.10;

/// An item surfaced this few windows ago pulses instead of surfacing again.
const kSurfaceQuiet = 3;

/// The lifts above are the CPU 740M's. The SM8850 NPU bundle spreads the
/// same meeting about twice as wide (Galaxy S26+, 2026-10-13: matches lift
/// 0.27–0.35, the best non-match 0.115, small talk 0.048), so on the NPU the
/// two lift thresholds are scaled by this (the margin is not).
const kSurfaceNpuScale = 2.0;

/// What a question asked by voice is called on screen and in the log: it is
/// never written out.
const kSpokenLabel = 'Spoken question';

/// One question answered: what was retrieved, what was sent, and the reply
/// as it streams.
final class AnswerRun extends ChangeNotifier {
  String? question;

  /// The question as sound, when it was spoken: the voice bubble shows its
  /// waveform, never its words.
  Uint8List? spoken;
  List<double> spokenLevels = const [];

  /// The spoken question is still coming in ("as if from the microphone").
  bool listening = false;

  /// When in the meeting the question was heard (Live).
  Duration? heardAt;
  List<MultimodalRagSource> sources = const [];

  /// The reply, as it streams.
  final ValueNotifier<String> text = ValueNotifier('');
  bool busy = false;

  /// Retrieval in all, and the part of it that embedded the query.
  Duration? retrievalTook;
  Duration? queryEmbedding;
  Duration? firstWordsAfter;
  Duration? answerTook;

  /// Stream chunks received (about one token each).
  int chunks = 0;
  bool sentImage = false;
  bool sentAudio = false;

  /// Chunks a second after the first one: about the decode speed.
  double? get chunksPerSecond {
    final first = firstWordsAfter;
    final all = answerTook;
    if (first == null || all == null || chunks < 2 || all <= first) {
      return null;
    }
    return (chunks - 1) / ((all - first).inMicroseconds / 1e6);
  }

  void _start(String question, {Uint8List? spoken, Duration? heardAt}) {
    this.question = question;
    this.spoken = spoken;
    spokenLevels = spoken == null ? const [] : waveformLevels(spoken);
    this.heardAt = heardAt;
    sources = const [];
    text.value = '';
    busy = true;
    retrievalTook = queryEmbedding = firstWordsAfter = answerTook = null;
    chunks = 0;
    sentImage = sentAudio = false;
    notifyListeners();
  }

  void _changed() => notifyListeners();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }
}

/// A library item Live surfaced: what a window of the meeting was about,
/// found by its sound.
final class SurfacedItem {
  SurfacedItem({
    required this.item,
    required this.heardAt,
    required this.window,
    required this.lift,
  }) : lastWindow = window;

  final MultimodalRagItem item;
  final Duration heardAt;
  final int window;
  final double lift;

  /// How often it matched again since, and the window it last did.
  int pulses = 0;
  int lastWindow;
}

/// The Multimodal RAG screen's state and commands: a knowledge base of notes,
/// photos and voice memos in three RAG indexes over one EmbeddingGemma 2
/// space (the active embedder), searched by text (as you type), by photo,
/// and by what was said in a meeting (Live); and questions answered by the
/// active language model from what the search retrieves, with the retrieved
/// photo and recording sent along.
///
/// Every failure lands in [error] (or, per item, in [failureOf]) for the
/// screen to show; nothing is swallowed.
final class MultimodalRagViewModel extends ChangeNotifier {
  MultimodalRagViewModel(this._deps);

  final MultimodalRagDependencies _deps;
  MultimodalRagIndex? _index;

  /// [kSurfaceNpuScale] when the embedder runs on an NPU, else 1.
  double _liftScale = 1;
  MultimodalRagLibrary _library = MultimodalRagLibrary.seeded();
  bool _disposed = false;
  Timer? _recordingLimit;
  Timer? _typing;
  Future<void>? _warmUp;
  Future<void> _llmQueue = Future.value();

  // ── Setup ────────────────────────────────────────────────────────────────

  MultimodalRagStatus status = MultimodalRagStatus.loading;
  MultimodalRagSetup? setup;

  /// How long opening the indexes took (loading the embedder included).
  Duration? openTook;

  /// The last failure, ready to show; null when nothing failed.
  String? error;

  // ── Library and index ────────────────────────────────────────────────────

  final Map<String, String> _failures = {};
  final Set<String> _queued = {};
  String? indexingId;
  bool indexing = false;

  /// How long the last indexing run took.
  Duration? lastRunTook;

  /// Items of the kinds this platform has (memos are not on the web).
  List<MultimodalRagItem> get items => [
    for (final item in _library.items)
      if (item.kind != MultimodalRagKind.memo ||
          (setup?.audioSupported ?? false))
        item,
  ];

  List<MultimodalRagItem> itemsOf(MultimodalRagKind kind) => [
    for (final item in items)
      if (item.kind == kind) item,
  ];

  /// What embedding [id] cost, or null when it is not indexed.
  Duration? costOf(String id) => switch (setup?.embedder) {
    final embedder? => _library.indexedIn(embedder.textProfileId)[id],
    null => null,
  };

  String? failureOf(String id) => _failures[id];

  bool isQueued(String id) => _queued.contains(id);

  /// What a photo reference shows.
  ImageProvider imageFor(String reference) => _deps.media.imageFor(reference);

  /// Whether the active embedder indexes [kind] at all.
  bool indexes(MultimodalRagKind kind) =>
      setup?.embedder?.kinds.contains(kind) ?? false;

  int get indexedCount => items.where((item) => costOf(item.id) != null).length;

  /// Items the active embedder could index that are not indexed yet.
  List<MultimodalRagItem> get pending => [
    for (final item in items)
      if (indexes(item.kind) && costOf(item.id) == null) item,
  ];

  bool get busy => indexing || recording || keepingMemo;

  // ── Search ───────────────────────────────────────────────────────────────

  /// What [results] answer: the query, or "photos like …".
  String? resultsFor;

  /// The photo [results] are like, for "Find similar".
  PhotoItem? similarTo;
  List<MultimodalRagResult> results = const [];
  Duration? searchTook;
  Duration? searchEmbedding;
  bool searching = false;
  String? _nextQuery;

  // ── Ask ──────────────────────────────────────────────────────────────────

  LlmState llmState = LlmState.missing;
  String? llmBackend;
  Duration? llmLoadTook;

  /// The Ask tab's question and answer.
  final AnswerRun askRun = AnswerRun();

  // ── Live ─────────────────────────────────────────────────────────────────

  LiveState liveState = LiveState.idle;

  /// "Sample meeting" or "Microphone": where Live listens.
  String liveSource = 'Sample meeting';

  /// Every window heard so far (Live's plumbing: not shown, but timed).
  final List<MeetingWindow> windows = [];

  /// The audio level, for the meter, and its recent history for the
  /// waveform.
  final ValueNotifier<double> level = ValueNotifier(0);
  final ValueNotifier<List<double>> levels = ValueNotifier(const []);

  /// How much of the meeting has been heard.
  Duration heard = Duration.zero;

  /// What the meeting surfaced from the library, in order.
  final List<SurfacedItem> surfaced = [];

  /// The question Live heard (or "what was just said"), answered.
  final AnswerRun liveRun = AnswerRun();

  /// The window "When did we talk about …" found, and the query.
  int? meetingHit;
  String? meetingQuery;
  Duration? meetingSearchTook;

  /// Bumped on every Live event a viewer should be scrolled to.
  final ValueNotifier<int> liveEvents = ValueNotifier(0);

  /// Median times per window: EmbeddingGemma 2 embedding the sound, and
  /// Gemma 4 hearing it.
  Duration? get windowEmbedding =>
      _median([for (final w in windows) ?w.embedTook]);
  Duration? get windowHearing => _median([for (final w in windows) ?w.heardIn]);

  RagIndex? _meetingIndex;
  MeetingWindower? _windower;
  StreamSubscription<Uint8List>? _microphone;
  Timer? _feed;
  final List<MeetingWindow> _toProcess = [];
  bool _processing = false;
  bool _feedEnded = false;

  static Duration? _median(List<Duration> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  // ── Memos ────────────────────────────────────────────────────────────────

  /// The memo playing, or null.
  final ValueNotifier<String?> playing = ValueNotifier(null);
  bool recording = false;
  DateTime? recordingSince;
  bool keepingMemo = false;

  // ── Commands: setup and library ──────────────────────────────────────────

  /// Reads what the model lists left active, loads the embedder and opens
  /// the indexes. Called again after the user went to a model list.
  Future<void> open() async {
    _set(() {
      status = MultimodalRagStatus.loading;
      error = null;
    });
    final previous = _index;
    final previousMeeting = _meetingIndex;
    _index = null;
    _meetingIndex = null;
    try {
      await previous?.dispose();
      await previousMeeting?.dispose();
      final setup = await _deps.readSetup();
      if (_disposed) return;
      this.setup = setup;
      _library = MultimodalRagLibrary.decode(await _deps.library.read());
      llmState = setup.llm == null ? LlmState.missing : LlmState.idle;
      final embedder = setup.embedder;
      if (embedder == null) {
        _set(() {
          status = MultimodalRagStatus.failed;
          error = setup.embedderProblem;
        });
        return;
      }
      await _beforeEmbedding();
      final watch = Stopwatch()..start();
      final index = await _deps.openMultimodalRagIndex(embedder);
      if (_disposed) {
        await index.dispose();
        return;
      }
      _index = index;
      _liftScale = embedder.backend?.name == 'npu' ? kSurfaceNpuScale : 1;
      await _reconcile(index, embedder);
      _set(() {
        openTook = watch.elapsed;
        status = MultimodalRagStatus.ready;
      });
      debugPrint(
        '[Multimodal RAG] ready: ${embedder.name} on '
        '${embedder.backend?.name ?? 'cpu'}, ${index.counts} documents, '
        'opened in ${watch.elapsedMilliseconds} ms',
      );
      if (pending.isEmpty) _startWarmUp();
    } catch (e, st) {
      debugPrint('[Multimodal RAG] open failed: $e\n$st');
      _set(() {
        status = MultimodalRagStatus.failed;
        error = _describe(e);
      });
    }
  }

  /// Drops saved index state that the index itself contradicts: when a
  /// kind's index holds another number of documents than the library thinks
  /// (another app version, an interrupted run), that kind's index is emptied
  /// and its items are indexed again — so no document of an item the library
  /// no longer has is left to skew the ranking.
  Future<void> _reconcile(
    MultimodalRagIndex index,
    MultimodalRagEmbedderInfo embedder,
  ) async {
    final indexed = _library.indexedIn(embedder.textProfileId);
    for (final kind in index.kinds) {
      final saved = indexed.keys
          .where((id) => _library.byId(id)?.kind == kind)
          .length;
      if (saved != index.counts[kind]) {
        _library.forgetIndexed(embedder.textProfileId, kind: kind);
        if (index.counts[kind] != 0) await index.clearKind(kind);
      }
    }
  }

  /// Indexes every item that is not indexed yet: notes as text, photos as
  /// pixels, memos as sound. One item at a time; each item's cost is kept.
  Future<void> indexLibrary() => _indexItems(pending);

  Future<void> _indexItems(List<MultimodalRagItem> items) async {
    final index = _index;
    final embedder = setup?.embedder;
    if (index == null || embedder == null || indexing || items.isEmpty) {
      return;
    }
    _set(() {
      indexing = true;
      error = null;
      _queued.addAll([for (final item in items) item.id]);
      for (final item in items) {
        _failures.remove(item.id);
      }
    });
    final run = Stopwatch()..start();
    try {
      await _beforeEmbedding();
      for (final item in items) {
        if (_disposed) return;
        _set(() => indexingId = item.id);
        try {
          final embed = await _indexOne(index, item);
          _library.markIndexed(embedder.textProfileId, item.id, embed);
        } on Object catch (e, st) {
          debugPrint('[Multimodal RAG] ${item.id} not indexed: $e\n$st');
          _failures[item.id] = _describe(e);
        } finally {
          _queued.remove(item.id);
        }
      }
      await index.flush();
      await _save();
      debugPrint(
        '[Multimodal RAG] ${_runSummary(items, embedder, run.elapsed)}',
      );
    } catch (e, st) {
      debugPrint('[Multimodal RAG] indexing failed: $e\n$st');
      error = _describe(e);
    } finally {
      _set(() {
        indexing = false;
        indexingId = null;
        _queued.clear();
        lastRunTook = run.elapsed;
      });
    }
    if (!_disposed) _startWarmUp();
  }

  /// "indexed 21 of 21 items in 6123 ms: 8 notes embed 412 ms, …", for the
  /// log.
  String _runSummary(
    List<MultimodalRagItem> items,
    MultimodalRagEmbedderInfo embedder,
    Duration took,
  ) {
    final costs = _library.indexedIn(embedder.textProfileId);
    final parts = <String>[];
    for (final kind in MultimodalRagKind.values) {
      final done = [
        for (final item in items)
          if (item.kind == kind) ?costs[item.id],
      ];
      if (done.isEmpty) continue;
      final ms = [for (final d in done) d.inMilliseconds]..sort();
      parts.add(
        '${done.length} ${kind.plural.toLowerCase()} embed '
        '${ms.fold(0, (a, b) => a + b)} ms (median ${ms[ms.length ~/ 2]})',
      );
    }
    return 'indexed ${items.length - _failures.length} of ${items.length} '
        'items in ${took.inMilliseconds} ms: ${parts.join(', ')}';
  }

  Future<Duration> _indexOne(
    MultimodalRagIndex index,
    MultimodalRagItem item,
  ) async {
    switch (item) {
      case NoteItem():
        return index.addNote(item);
      case PhotoItem(:final reference):
        final prepared = await _deps.preparePhoto(
          await _deps.media.read(reference),
        );
        return index.addPhoto(item, prepared.bytes);
      case MemoItem(:final reference):
        return index.addMemo(item, await _deps.media.read(reference));
    }
  }

  /// Empties the indexes; the library keeps its items (Index adds them
  /// again).
  Future<void> clearIndex() async {
    final index = _index;
    final embedder = setup?.embedder;
    if (index == null || embedder == null || busy) return;
    try {
      await index.clear();
      _library.forgetIndexed(embedder.textProfileId);
      _failures.clear();
      await _save();
      _set(() {
        results = const [];
        resultsFor = null;
        lastRunTook = null;
      });
    } catch (e, st) {
      debugPrint('[Multimodal RAG] clear failed: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  // ── Commands: search ─────────────────────────────────────────────────────

  /// Search as you type: searches [text] once typing pauses.
  void queryChanged(String text) {
    _typing?.cancel();
    if (text.trim().length < 3) return;
    _typing = Timer(kTypingPause, () => unawaited(search(text)));
  }

  /// Text → notes, photos and voice memos, ranked together. A search asked
  /// for while one runs follows it (the latest wins).
  Future<void> search(String query) async {
    final text = query.trim();
    final index = _index;
    if (text.isEmpty || index == null) return;
    if (searching) {
      _nextQuery = text;
      return;
    }
    _set(() {
      searching = true;
      error = null;
    });
    try {
      await _beforeEmbedding();
      final watch = Stopwatch()..start();
      final hits = await index.search(text);
      watch.stop();
      _set(() {
        resultsFor = text;
        similarTo = null;
        results = _withItems(hits);
        searchTook = watch.elapsed;
        searchEmbedding = index.lastQueryEmbedding;
      });
      debugPrint(
        '[Multimodal RAG] search "$text": ${watch.elapsedMilliseconds} ms '
        '(query embedding ${index.lastQueryEmbedding.inMilliseconds} ms): '
        '${_describeHits(results)}',
      );
    } catch (e, st) {
      debugPrint('[Multimodal RAG] search failed: $e\n$st');
      _set(() => error = _describe(e));
    } finally {
      _set(() => searching = false);
    }
    final next = _nextQuery;
    _nextQuery = null;
    if (next != null && next != text && !_disposed) await search(next);
  }

  /// Photo → photos: the photos closest to [photo], by their pixels.
  Future<void> findSimilar(PhotoItem photo) async {
    final index = _index;
    if (index == null || searching || !indexes(MultimodalRagKind.photo)) return;
    _set(() {
      searching = true;
      error = null;
    });
    try {
      await _beforeEmbedding();
      final watch = Stopwatch()..start();
      final prepared = await _deps.preparePhoto(
        await _deps.media.read(photo.reference),
      );
      final hits = await index.searchBy(
        EmbeddingInput.image(prepared.bytes),
        kinds: const {MultimodalRagKind.photo},
        exclude: {photo.id},
      );
      watch.stop();
      _set(() {
        resultsFor = 'photos like ${photo.title}';
        similarTo = photo;
        results = _withItems(hits);
        searchTook = watch.elapsed;
        searchEmbedding = index.lastQueryEmbedding;
      });
      debugPrint(
        '[Multimodal RAG] similar to ${photo.id}: ${watch.elapsedMilliseconds} ms '
        '(image embedding ${index.lastQueryEmbedding.inMilliseconds} ms): '
        '${_describeHits(results)}',
      );
    } catch (e, st) {
      debugPrint('[Multimodal RAG] find similar failed: $e\n$st');
      _set(() => error = _describe(e));
    } finally {
      _set(() => searching = false);
    }
  }

  List<MultimodalRagResult> _withItems(List<RankedHit> hits) => [
    for (final hit in hits)
      if (_library.byId(hit.id) case final item?) (item: item, hit: hit),
  ];

  static String _describeHits(List<MultimodalRagResult> results) => [
    for (final r in results)
      '${r.item.id} lift ${r.hit.lift.toStringAsFixed(3)} '
          'cos ${r.hit.similarity.toStringAsFixed(3)}',
  ].join(', ');

  // ── Commands: ask ────────────────────────────────────────────────────────

  /// Retrieves the items closest to [text] across the three kinds, then
  /// streams the language model's answer, which cites them by number. The
  /// best photo is sent as an image and the best memo as a recording when
  /// the model takes them.
  Future<void> ask(String text) async {
    final question = text.trim();
    if (question.isEmpty || askRun.busy) return;
    await _answer(askRun, question);
  }

  Future<void> _answer(
    AnswerRun run,
    String question, {
    Uint8List? spokenQuestion,
    Duration? heardAt,
  }) async {
    final index = _index;
    final llm = setup?.llm;
    if (index == null) return;
    if (llm == null) {
      _set(() => error = 'No language model is active.');
      return;
    }
    run._start(question, spoken: spokenQuestion, heardAt: heardAt);
    try {
      await _beforeEmbedding();
      final watch = Stopwatch()..start();
      // A spoken question is the query as it is: EmbeddingGemma 2 embeds the
      // recording, which finds a photo or a note by what was said.
      final hits = spokenQuestion == null
          ? await index.search(question, limit: kAnswerSources)
          : await index.searchVector(
              await index.embedQuery(
                EmbeddingInput.audio(AudioConverter.pcmToWav(spokenQuestion)),
              ),
              limit: kAnswerSources,
            );
      run
        ..retrievalTook = watch.elapsed
        ..queryEmbedding = index.lastQueryEmbedding;
      final retrieved = _withItems(hits);
      // The best photo is looked at when it is among the first two sources;
      // a memo is played only when it is the best source (and the question
      // is not itself a recording: one recording per message).
      final photo = llm.seesImages
          ? retrieved
                .take(2)
                .map((r) => r.item)
                .whereType<PhotoItem>()
                .firstOrNull
          : null;
      final memo =
          llm.hearsAudio &&
              spokenQuestion == null &&
              retrieved.firstOrNull?.item is MemoItem
          ? retrieved.first.item as MemoItem
          : null;
      run.sources = [
        for (final (i, result) in retrieved.indexed)
          (
            number: i + 1,
            item: result.item,
            attached:
                identical(result.item, photo) || identical(result.item, memo),
          ),
      ];
      run._changed();
      final image = photo == null
          ? null
          : (await _deps.preparePhoto(
              await _deps.media.read(photo.reference),
            )).bytes;
      final audio = spokenQuestion != null
          ? AudioConverter.pcmToWav(spokenQuestion)
          : memo == null
          ? null
          : await _deps.media.read(memo.reference);
      run
        ..sentImage = image != null
        ..sentAudio = audio != null;
      final sent = [
        if (photo != null) 'image ${photo.id}',
        if (memo != null) 'audio ${memo.id}',
        if (spokenQuestion != null) 'the spoken question',
      ];
      debugPrint(
        '[Multimodal RAG] ask "$question": retrieved in '
        '${run.retrievalTook!.inMilliseconds} ms (query embedding '
        '${run.queryEmbedding!.inMilliseconds} ms): '
        '${_describeHits(retrieved)}; sending '
        '${sent.isEmpty ? 'text only' : sent.join(' + ')}',
      );
      await _deps.beforeAnswer();
      await _withLlm(() async {
        await _ensureWarm();
        watch.reset();
        final stream = _deps.answerer.answer(
          systemInstruction: kMultimodalRagSystemInstruction,
          prompt: buildMultimodalRagPrompt(
            question,
            run.sources,
            spoken: spokenQuestion != null,
          ),
          images: [?image],
          audio: audio,
        );
        await for (final chunk in stream) {
          if (_disposed) return;
          run
            ..firstWordsAfter ??= watch.elapsed
            ..chunks += 1;
          run.text.value += chunk;
        }
        run.answerTook = watch.elapsed;
      });
      debugPrint(
        '[Multimodal RAG] answered "$question": first words after '
        '${run.firstWordsAfter?.inMilliseconds} ms, '
        '${run.answerTook?.inMilliseconds} ms in all, ${run.chunks} chunks '
        '(${run.chunksPerSecond?.toStringAsFixed(1)}/s) on $llmBackend: '
        '"${run.text.value.trim()}"',
      );
    } catch (e, st) {
      debugPrint('[Multimodal RAG] answer failed: $e\n$st');
      error = _describe(e);
    } finally {
      if (!_disposed) {
        run
          ..busy = false
          .._changed();
        _notify();
        if (identical(run, liveRun)) liveEvents.value++;
      }
    }
  }

  Future<void> stopAnswer() async {
    try {
      await _deps.answerer.stop();
    } catch (e, st) {
      debugPrint('[Multimodal RAG] stop failed: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  /// One language-model call at a time: Ask, Live's listening and its
  /// answers share the one model and its one session.
  Future<T> _withLlm<T>(Future<T> Function() call) {
    final result = _llmQueue.then((_) => call());
    _llmQueue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Loads the language model in the background, once nothing is waiting to
  /// be indexed, so the first question does not wait for it. Not on the web,
  /// where it would push the vision encoder out of memory
  /// ([MultimodalRagSetup.preloadLlm]).
  void _startWarmUp() {
    if (setup?.preloadLlm != true) return;
    if (llmState != LlmState.idle && llmState != LlmState.failed) return;
    unawaited(
      _ensureWarm().catchError((Object e, StackTrace st) {
        debugPrint('[Multimodal RAG] language model failed to load: $e\n$st');
      }),
    );
  }

  Future<void> _ensureWarm() {
    if (setup?.llm == null) {
      return Future.error(StateError('No language model is active.'));
    }
    if (llmState == LlmState.ready) return Future.value();
    return _warmUp ??= () async {
      _set(() => llmState = LlmState.loading);
      final watch = Stopwatch()..start();
      try {
        final backend = await _deps.answerer.warmUp();
        _set(() {
          llmBackend = backend;
          llmLoadTook = watch.elapsed;
          llmState = LlmState.ready;
        });
        debugPrint(
          '[Multimodal RAG] language model loaded in ${watch.elapsedMilliseconds} '
          'ms on $backend',
        );
      } catch (e) {
        _set(() => llmState = LlmState.failed);
        rethrow;
      } finally {
        _warmUp = null;
      }
    }();
  }

  /// On the web the language model is released to embed (see
  /// [MultimodalRagDependencies.beforeEmbedding]); it loads again on the next
  /// question.
  Future<void> _beforeEmbedding() async {
    if (await _deps.beforeEmbedding() && llmState == LlmState.ready) {
      _set(() => llmState = LlmState.idle);
    }
  }

  // ── Commands: Live ───────────────────────────────────────────────────────

  /// Where Live listens: "Sample meeting" or "Microphone".
  void chooseLiveSource(String source) {
    if (liveState == LiveState.listening) return;
    _set(() => liveSource = source);
  }

  /// Starts listening to the chosen source.
  Future<void> startLive() =>
      liveSource == 'Microphone' ? startMicrophone() : startSampleMeeting();

  /// Plays the bundled meeting and feeds it to Live as if it came from the
  /// microphone, in real time.
  Future<void> startSampleMeeting() async {
    if (!await _startLive('Sample meeting')) return;
    try {
      final pcm = pcm16kMonoFromWav(await _deps.media.read(kSampleMeeting));
      final started = _deps.now();
      unawaited(
        _deps.player.play(kSampleMeeting).catchError((Object e) {
          debugPrint('[Multimodal RAG] the meeting did not play: $e');
        }),
      );
      debugPrint(
        '[Multimodal RAG] live: sample meeting (${pcmDuration(pcm).inMilliseconds}'
        ' ms) started at ${started.millisecondsSinceEpoch}',
      );
      var fed = 0;
      _feed = Timer.periodic(const Duration(milliseconds: 100), (_) {
        // As much as real time has played: a late tick catches up.
        final due =
            (_deps.now().difference(started).inMicroseconds *
                kPcmBytesPerSecond ~/
                Duration.microsecondsPerSecond) &
            ~1;
        final end = due.clamp(0, pcm.length);
        if (end > fed) {
          _onAudio(Uint8List.sublistView(pcm, fed, end));
          fed = end;
        }
        if (fed >= pcm.length) _endFeed();
      });
    } catch (e, st) {
      debugPrint('[Multimodal RAG] live failed: $e\n$st');
      _set(() => error = _describe(e));
      _endFeed();
    }
  }

  /// Listens to the microphone.
  Future<void> startMicrophone() async {
    if (!await _startLive('Microphone')) return;
    _microphone = _deps.microphone().listen(
      _onAudio,
      onError: (Object e, StackTrace st) {
        debugPrint('[Multimodal RAG] microphone failed: $e\n$st');
        _set(() => error = _describe(e));
        _endFeed();
      },
      onDone: _endFeed,
    );
  }

  /// Stops listening; the windows heard so far are still processed.
  Future<void> stopLive() async {
    if (liveState != LiveState.listening) return;
    await _deps.player.stop();
    _endFeed();
  }

  Future<bool> _startLive(String source) async {
    final embedder = setup?.embedder;
    if (embedder == null ||
        !(setup?.liveSupported ?? false) ||
        liveState == LiveState.listening) {
      return false;
    }
    try {
      final meeting = _meetingIndex ??= await _deps.openMeetingIndex(embedder);
      await meeting.clear();
    } catch (e, st) {
      debugPrint('[Multimodal RAG] meeting index failed: $e\n$st');
      _set(() => error = _describe(e));
      return false;
    }
    _set(() {
      liveState = LiveState.listening;
      liveSource = source;
      windows.clear();
      surfaced.clear();
      _toProcess.clear();
      heard = Duration.zero;
      meetingHit = null;
      meetingQuery = null;
      _feedEnded = false;
      _windower = MeetingWindower();
      levels.value = const [];
      error = null;
    });
    return true;
  }

  void _onAudio(Uint8List chunk) {
    final windower = _windower;
    if (windower == null || _disposed) return;
    level.value = pcmLevel(chunk);
    final history = [...levels.value, level.value];
    levels.value = history.length > 64
        ? history.sublist(history.length - 64)
        : history;
    for (final window in windower.add(chunk)) {
      _queueWindow(window);
    }
    heard = windower.heard;
    _notify();
  }

  void _queueWindow(({Duration start, Uint8List pcm}) window) {
    final w = MeetingWindow(
      index: windows.length,
      start: window.start,
      pcm: window.pcm,
    );
    windows.add(w);
    _toProcess.add(w);
    unawaited(_processWindows());
  }

  void _endFeed() {
    _feed?.cancel();
    _feed = null;
    unawaited(_microphone?.cancel());
    _microphone = null;
    if (_feedEnded) return;
    _feedEnded = true;
    level.value = 0;
    if (_windower?.flush() case final tail?) _queueWindow(tail);
    if (!_processing) _set(() => liveState = LiveState.finished);
  }

  /// Each window, in order: EmbeddingGemma 2 embeds its sound once — filed in
  /// the meeting index, and searched against the library, which may surface
  /// an item — then Gemma 4 hears it and names a question if one was asked.
  /// A window that arrives while the model is still busy with an older one
  /// is filed and searched but not heard, so Live stays live.
  Future<void> _processWindows() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_toProcess.isNotEmpty && !_disposed) {
        final w = _toProcess.removeAt(0);
        final wav = AudioConverter.pcmToWav(w.pcm);
        await _fileWindow(w, wav);
        if (_toProcess.isNotEmpty || liveRun.busy) {
          w.verdict = WindowVerdict.skipped;
          debugPrint(
            '[Multimodal RAG] live window ${w.index} ${_span(w)}: not heard '
            '(${liveRun.busy ? 'answering' : 'behind'})',
          );
          _notify();
          continue;
        }
        await _hearWindow(w, wav);
      }
    } finally {
      _processing = false;
      if (_feedEnded && !_disposed) _set(() => liveState = LiveState.finished);
    }
  }

  /// Embeds [w] once: into the meeting index, and as a query against the
  /// library.
  Future<void> _fileWindow(MeetingWindow w, Uint8List wav) async {
    final meeting = _meetingIndex;
    final index = _index;
    if (meeting == null || index == null) return;
    try {
      final vector = await index.embedQuery(EmbeddingInput.audio(wav));
      w.embedTook = index.lastQueryEmbedding;
      await meeting.addVector(
        id: 'w${w.index}',
        embedding: vector,
        content: 'w${w.index}',
      );
      final hits = await index.searchVector(vector, minLift: -1, limit: 3);
      debugPrint(
        '[Multimodal RAG] live window ${w.index} ${_span(w)}: EG2 '
        '${w.embedTook?.inMilliseconds} ms, top ${[for (final h in hits) '${h.id} ${h.lift.toStringAsFixed(3)}'].join(', ')}',
      );
      _surface(w, hits);
    } catch (e, st) {
      debugPrint('[Multimodal RAG] window ${w.index} not filed: $e\n$st');
      w.error = _describe(e);
    }
  }

  /// Surfaces what [w] was about: its best library match, when it clears
  /// [kSurfaceLift] by [kSurfaceMargin], and the runner-up of another kind
  /// at [kSurfaceSecondLift]. An item surfaced in the last [kSurfaceQuiet]
  /// windows pulses instead.
  void _surface(MeetingWindow w, List<RankedHit> hits) {
    if (hits.isEmpty || _disposed) return;
    final top = hits.first;
    final margin = top.lift - (hits.length > 1 ? hits[1].lift : 0);
    // The margin is not scaled: on the NPU the Q3 note and its chart come
    // 0.034 apart, and the lift alone keeps the non-matches out.
    if (top.lift < kSurfaceLift * _liftScale || margin < kSurfaceMargin) {
      return;
    }
    final added = _surfaceOne(w, top);
    if (added &&
        hits.length > 1 &&
        hits[1].kind != top.kind &&
        hits[1].lift >= kSurfaceSecondLift * _liftScale) {
      _surfaceOne(w, hits[1]);
    }
    liveEvents.value++;
    _notify();
  }

  /// True when [hit] surfaced anew, false when it pulsed.
  bool _surfaceOne(MeetingWindow w, RankedHit hit) {
    final item = _library.byId(hit.id);
    if (item == null) return false;
    final earlier = surfaced.where((s) => s.item.id == hit.id).lastOrNull;
    if (earlier != null && w.index - earlier.lastWindow <= kSurfaceQuiet) {
      earlier
        ..pulses += 1
        ..lastWindow = w.index;
      debugPrint(
        '[Multimodal RAG] live: ${hit.id} again at ${_span(w)} (pulse)',
      );
      return false;
    }
    surfaced.add(
      SurfacedItem(
        item: item,
        heardAt: w.start,
        window: w.index,
        lift: hit.lift,
      ),
    );
    debugPrint(
      '[Multimodal RAG] live: surfaced ${hit.id} at ${_span(w)} '
      '(lift ${hit.lift.toStringAsFixed(3)})',
    );
    return true;
  }

  Future<void> _hearWindow(MeetingWindow w, Uint8List wav) async {
    _set(() => w.verdict = WindowVerdict.listening);
    try {
      final reply = await _withLlm(() async {
        await _ensureWarm();
        final watch = Stopwatch()..start();
        final text = StringBuffer();
        await for (final chunk in _deps.answerer.answer(
          systemInstruction: kLiveListenInstruction,
          prompt: kLiveListenPrompt,
          audio: wav,
          maxOutputTokens: 40,
        )) {
          text.write(chunk);
        }
        w.heardIn = watch.elapsed;
        return text.toString();
      });
      final question = parseLiveQuestion(reply);
      w
        ..question = question
        ..verdict = question == null
            ? WindowVerdict.none
            : WindowVerdict.question;
      debugPrint(
        '[Multimodal RAG] live window ${w.index} ${_span(w)}: Gemma 4 heard it in '
        '${w.heardIn?.inMilliseconds} ms → ${reply.trim()}',
      );
      _notify();
      if (question != null && !liveRun.busy && !_disposed) {
        liveEvents.value++;
        unawaited(_answer(liveRun, question, heardAt: w.start));
      }
    } catch (e, st) {
      debugPrint('[Multimodal RAG] window ${w.index} not heard: $e\n$st');
      _set(() {
        w
          ..verdict = WindowVerdict.failed
          ..error = _describe(e);
      });
    }
  }

  static String _span(MeetingWindow w) =>
      '${(w.start.inMilliseconds / 1000).toStringAsFixed(1)}–'
      '${(w.end.inMilliseconds / 1000).toStringAsFixed(1)} s';

  /// The fallback: retrieval by the SOUND of the last seconds (EmbeddingGemma
  /// 2 embeds the recording as the query), and the language model hears
  /// them too and answers the question asked in them.
  Future<void> answerWhatWasJustSaid() async {
    if (liveRun.busy || windows.isEmpty) return;
    final parts = <Uint8List>[];
    var length = Duration.zero;
    for (final w in windows.reversed) {
      if (length + pcmDuration(w.pcm) > kJustSaid && parts.isNotEmpty) break;
      parts.insert(0, w.pcm);
      length += pcmDuration(w.pcm);
    }
    final builder = BytesBuilder(copy: false);
    parts.forEach(builder.add);
    debugPrint(
      '[Multimodal RAG] answer what was just said: the last '
      '${length.inMilliseconds} ms',
    );
    if (_disposed) return;
    liveEvents.value++;
    await _answer(
      liveRun,
      'What was just said',
      spokenQuestion: builder.takeBytes(),
      heardAt: windows.last.start,
    );
  }

  /// Makes [s] glow (a jump to it from the timeline).
  void pulse(SurfacedItem s) {
    s.pulses += 1;
    _notify();
  }

  /// "When did we talk about …": the meeting window closest to [text].
  Future<void> searchMeeting(String text) async {
    final query = text.trim();
    final meeting = _meetingIndex;
    if (query.isEmpty || meeting == null || windows.isEmpty) return;
    try {
      final watch = Stopwatch()..start();
      final hits = await meeting.search(
        query: EmbeddingInput.text(query),
        topK: windows.length,
      );
      watch.stop();
      final top = hits.firstOrNull;
      _set(() {
        meetingQuery = query;
        meetingSearchTook = watch.elapsed;
        meetingHit = top == null ? null : int.tryParse(top.id.substring(1));
      });
      final ranked = [
        for (final h in hits.take(3))
          '${h.id} ${h.similarity.toStringAsFixed(3)}',
      ];
      debugPrint(
        '[Multimodal RAG] meeting search "$query": ${watch.elapsedMilliseconds} '
        'ms → ${ranked.join(', ')}',
      );
    } catch (e, st) {
      debugPrint('[Multimodal RAG] meeting search failed: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  // ── Commands: ask by voice ───────────────────────────────────────────────

  /// "Ask by voice" with the bundled spoken question, fed as if from the
  /// microphone: it plays, then the recording itself is the query —
  /// EmbeddingGemma 2 embeds the sound, which finds the photo or note by
  /// what was asked — and Gemma 4 hears it along with the retrieved photo.
  /// Nothing is transcribed.
  Future<void> askSampleByVoice() async {
    if (askRun.busy) return;
    try {
      final pcm = pcm16kMonoFromWav(await _deps.media.read(kSampleQuestion));
      await _askByVoice(pcm, play: kSampleQuestion);
    } catch (e, st) {
      debugPrint('[Multimodal RAG] ask by voice failed: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  /// Starts recording a spoken question; [stopVoiceQuestion] asks it.
  Future<void> startVoiceQuestion() async {
    if (askRun.busy || busy) return;
    try {
      await _deps.recorder.start();
      _set(() => recordingQuestion = true);
    } catch (e, st) {
      debugPrint('[Multimodal RAG] recording failed: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  Future<void> stopVoiceQuestion() async {
    if (!recordingQuestion) return;
    _set(() => recordingQuestion = false);
    try {
      final pcm = pcm16kMonoFromWav(await _deps.recorder.stop());
      if (pcm.isEmpty) throw StateError('The recording is empty.');
      await _askByVoice(pcm);
    } catch (e, st) {
      debugPrint('[Multimodal RAG] ask by voice failed: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  /// A spoken question is being recorded.
  bool recordingQuestion = false;

  Future<void> _askByVoice(Uint8List pcm, {String? play}) async {
    if (play != null) {
      // As if it came from the microphone: the bubble fills while it plays.
      askRun
        .._start(kSpokenLabel, spoken: pcm)
        ..listening = true
        .._changed();
      final started = _deps.now();
      unawaited(
        _deps.player.play(play).catchError((Object e) {
          debugPrint('[Multimodal RAG] the question did not play: $e');
        }),
      );
      debugPrint(
        '[Multimodal RAG] ask by voice: ${pcmDuration(pcm).inMilliseconds} ms of '
        'audio started at ${started.millisecondsSinceEpoch}',
      );
      await Future<void>.delayed(pcmDuration(pcm));
      if (_disposed) return;
      askRun
        ..listening = false
        .._changed();
    }
    await _answer(askRun, kSpokenLabel, spokenQuestion: pcm);
  }

  // ── Commands: memos, notes, photos ───────────────────────────────────────

  /// Plays [memo], or stops it when it is playing.
  Future<void> togglePlay(MemoItem memo) async {
    if (playing.value == memo.id) {
      await _deps.player.stop();
      return;
    }
    try {
      if (playing.value != null) await _deps.player.stop();
      playing.value = memo.id;
      await _deps.player.play(memo.reference);
    } catch (e, st) {
      debugPrint('[Multimodal RAG] playback failed: $e\n$st');
      _set(() => error = _describe(e));
    } finally {
      if (!_disposed && playing.value == memo.id) playing.value = null;
    }
  }

  /// Adds a note and indexes it.
  Future<void> addNote({required String title, required String body}) async {
    final note = NoteItem(
      id: 'note-${_deps.now().microsecondsSinceEpoch}',
      title: title.trim().isEmpty ? 'Untitled note' : title.trim(),
      body: body.trim(),
    );
    await _addAndIndex(note);
  }

  /// Lets the user pick a photo, keeps a copy and indexes it.
  Future<void> addPhoto() async {
    if (busy) return;
    try {
      final picked = await _deps.pickPhoto();
      if (picked == null || _disposed) return;
      // Decoded before it is kept: a format this platform cannot decode is
      // refused here, before a copy exists.
      await _deps.preparePhoto(picked.bytes);
      final reference = await _deps.media.keepPhoto(
        picked.bytes,
        name: picked.name,
      );
      final number = itemsOf(MultimodalRagKind.photo).length + 1;
      await _addAndIndex(
        PhotoItem(
          id: 'photo-${_deps.now().microsecondsSinceEpoch}',
          title: 'Photo $number',
          reference: reference,
        ),
      );
    } catch (e, st) {
      debugPrint('[Multimodal RAG] photo not added: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  /// Starts recording a voice memo (at most [kMaxMemo]).
  Future<void> startRecording() async {
    if (busy || !(setup?.audioSupported ?? false)) return;
    try {
      await _deps.recorder.start();
      _set(() {
        recording = true;
        recordingSince = _deps.now();
        error = null;
      });
      _recordingLimit = Timer(kMaxMemo, () => unawaited(stopRecording()));
    } catch (e, st) {
      debugPrint('[Multimodal RAG] recording failed: $e\n$st');
      _set(() => error = _describe(e));
    }
  }

  /// Stops recording, keeps the memo and indexes it.
  Future<void> stopRecording() async {
    if (!recording) return;
    _recordingLimit?.cancel();
    _recordingLimit = null;
    _set(() {
      recording = false;
      recordingSince = null;
      keepingMemo = true;
    });
    try {
      final wav = await _deps.recorder.stop();
      final pcm = pcm16kMonoFromWav(wav);
      if (pcm.isEmpty) throw StateError('The recording is empty.');
      final reference = await _deps.media.keepMemo(wav);
      final number = itemsOf(MultimodalRagKind.memo).length + 1;
      final memo = MemoItem(
        id: 'memo-${_deps.now().microsecondsSinceEpoch}',
        title: 'Voice memo $number',
        reference: reference,
        duration: pcmDuration(pcm),
      );
      _set(() => keepingMemo = false);
      await _addAndIndex(memo);
    } catch (e, st) {
      debugPrint('[Multimodal RAG] memo not added: $e\n$st');
      _set(() => error = _describe(e));
    } finally {
      if (keepingMemo) _set(() => keepingMemo = false);
    }
  }

  Future<void> _addAndIndex(MultimodalRagItem item) async {
    _library.add(item);
    await _save();
    _notify();
    if (indexes(item.kind)) await _indexItems([item]);
  }

  void clearError() => _set(() => error = null);

  Future<void> _save() => _deps.library.write(_library.encode());

  static String _describe(Object error) => switch (error) {
    PhotoDecodeException(:final message) =>
      'Could not decode that photo on this platform ($message).',
    EmbeddingException(:final message) => message,
    MultimodalRagRecorderException(:final message) => message,
    StateError(:final message) => message,
    ArgumentError(:final message) => '$message',
    _ => '$error',
  };

  void _set(void Function() change) {
    change();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _recordingLimit?.cancel();
    _typing?.cancel();
    _feed?.cancel();
    final microphone = _microphone;
    final index = _index;
    final meeting = _meetingIndex;
    _index = null;
    _meetingIndex = null;
    // dispose() cannot await: the indexes wait for accepted operations, then
    // close their stores. The models stay loaded (they are the app's).
    unawaited(
      () async {
        await microphone?.cancel();
        if (recording || recordingQuestion) await _deps.recorder.cancel();
        await _deps.player.stop();
        if (askRun.busy || liveRun.busy) await _deps.answerer.stop();
        await index?.dispose();
        await meeting?.dispose();
        await _deps.recorder.dispose();
        await _deps.player.dispose();
      }().catchError((Object e, StackTrace st) {
        debugPrint('[Multimodal RAG] closing failed: $e\n$st');
      }),
    );
    askRun.dispose();
    liveRun.dispose();
    level.dispose();
    levels.dispose();
    liveEvents.dispose();
    playing.dispose();
    super.dispose();
  }
}
