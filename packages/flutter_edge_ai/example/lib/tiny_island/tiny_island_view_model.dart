// The Decider API is @experimental; Tiny Island is its demo.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'island_catalog.dart';
import 'island_decider_preparation.dart';
import 'island_decider_recipe.dart';
import 'island_stage.dart';
import 'island_voice.dart';
import 'island_voice_recorder.dart';
import 'tiny_island_dependencies.dart';

enum TinyIslandStatus {
  /// Reading what is active, loading the embedder, reading a stored decider.
  loading,

  /// Fitting the decider: embedding the actions' texts (a visit with no
  /// stored decider for this model and catalog).
  preparing,
  ready,
  failed,
}

/// Whether the screen takes spoken requests.
enum TinyIslandVoiceStatus {
  /// Not with this bundle or platform; [TinyIslandViewModel.voiceNote] says
  /// why.
  off,

  /// Fitting the decider for spoken requests (after the typed one is ready).
  preparing,
  ready,

  /// Preparing it failed; [TinyIslandViewModel.voiceNote] says how. Typed
  /// requests still work.
  failed,
}

/// One request and what came of it. Written by the view model only.
final class TinyIslandTurn {
  TinyIslandTurn(this.request, {this.spoken});

  /// The typed text, or a label for a spoken request.
  final String request;

  /// How long a spoken request was; null for a typed one.
  final Duration? spoken;

  /// The Decider's answer; null while deciding, and when it failed.
  DeciderAnswer? answer;

  /// The chosen action; null while deciding, and when the Decider abstained.
  IslandAction? action;

  /// What the stage did; null until it has finished.
  IslandOutcome? outcome;

  /// What failed, ready to show.
  String? error;
}

/// The Tiny Island screen's state: core's Decider over the action catalog
/// (EmbeddingGemma 2, the active embedder), the requests sent to it, the 3D
/// scene's readiness, and what the island did.
///
/// Every failure is kept in [error] (or in the turn it belongs to) for the
/// screen to show — never swallowed, and never replaced by a fallback. A
/// failure that leaves no working Decider moves to
/// [TinyIslandStatus.failed], whose "Try again" calls [open].
///
/// The embedder is this screen's from the moment core hands it over: it is
/// closed when the screen reopens or leaves, through the app's
/// [IslandEmbedderLane].
final class TinyIslandViewModel extends ChangeNotifier {
  TinyIslandViewModel(this._deps, this._stage)
    : catalog = List.unmodifiable(_deps.catalog()) {
    _byId = {for (final action in catalog) action.id: action};
    if (_byId.length != catalog.length) {
      throw StateError('The island catalog repeats an action id.');
    }
    _recipe = _deps.recipe(catalog);
  }

  final TinyIslandDependencies _deps;
  final IslandStage _stage;
  final List<IslandAction> catalog;
  late final Map<String, IslandAction> _byId;
  late final IslandDeciderRecipe _recipe;

  /// The active bundle's, set by [open] when it takes spoken requests.
  IslandDeciderRecipe? _voiceRecipe;

  IslandEmbedderLane get _lane => _deps.lane ?? islandEmbedderLane;

  EmbeddingModel? _embedder;
  Decider? _decider;
  Decider? _voiceDecider;
  IslandVoiceRecorder? _recorder;

  /// The recorder's start, awaited by [stopListening] so a quick tap never
  /// stops a recording that has not started.
  Future<void>? _recording;
  bool _disposed = false;

  /// Bumped by every [open]: an older open that finishes late releases what
  /// it acquired instead of installing it.
  int _generation = 0;

  /// The current open's; cancelled when a newer open or dispose supersedes
  /// it, which stops `createDecider` embedding the catalog.
  CancelToken? _cancel;

  TinyIslandStatus get status => _status;
  TinyIslandStatus _status = TinyIslandStatus.loading;

  /// What failed last, ready to show; null when nothing did.
  String? get error => _error;
  String? _error;

  /// True when [error] is fixed by choosing another model on the list.
  bool get suggestModelList => _suggestModelList;
  bool _suggestModelList = false;

  /// The active embedder's name, once read.
  String? get embedderName => _embedderName;
  String? _embedderName;

  /// The backend the embedder reports (`cpu`, `npu`, `gpu`), once loaded;
  /// null when it reports none.
  String? get backend => _backend;
  String? _backend;

  /// Texts embedded so far while [status] is preparing.
  int get prepared => _prepared;
  int _prepared = 0;
  int get preparedOf => _preparedOf;
  int _preparedOf = 0;

  /// How long loading the model and the decider took.
  Duration? get prepareTime => _prepareTime;
  Duration? _prepareTime;

  /// How the decider came to be: loaded, fitted, fitted again and why,
  /// stored or not.
  String? get prepareNote => _prepareNote;
  String? _prepareNote;

  /// How the decider decides when to abstain.
  String get calibrationLabel => _recipe.calibrationLabel;

  /// Whether spoken requests are taken, and [voiceNote] about it.
  TinyIslandVoiceStatus get voiceStatus => _voiceStatus;
  TinyIslandVoiceStatus _voiceStatus = TinyIslandVoiceStatus.off;

  /// Why speaking is off or failed, or how its decider came to be; null
  /// until the active bundle is read.
  String? get voiceNote => _voiceNote;
  String? _voiceNote;

  /// How the spoken requests' decider decides when to abstain; empty while
  /// speaking is off.
  String get voiceCalibrationLabel => _voiceRecipe?.calibrationLabel ?? '';

  /// Texts embedded so far while [voiceStatus] is preparing.
  int get voicePrepared => _voicePrepared;
  int _voicePrepared = 0;
  int get voicePreparedOf => _voicePreparedOf;
  int _voicePreparedOf = 0;

  /// The microphone is recording a spoken request.
  bool get listening => _listening;
  bool _listening = false;

  /// Where fitted deciders are kept.
  String get storeWhere => _deps.store.where;

  /// A request is being decided.
  bool get deciding => _deciding;
  bool _deciding = false;

  /// Whether the 3D scene has loaded, or why it did not.
  bool get sceneReady => _sceneReady;
  bool _sceneReady = false;
  String? get sceneError => _sceneError;
  String? _sceneError;

  /// Whether a request can be sent now: the Decider and the scene are both
  /// ready, and no other request is being decided. Until then the input is
  /// disabled, so no request is dropped by a scene still loading.
  bool get canSend =>
      _status == TinyIslandStatus.ready &&
      _sceneReady &&
      _sceneError == null &&
      !_deciding;

  /// Whether the mic button can start a spoken request now.
  bool get canSpeak =>
      canSend &&
      _voiceStatus == TinyIslandVoiceStatus.ready &&
      _deps.recorder != null &&
      !_listening;

  /// Shorter recordings are a tap on the mic, not a request.
  static const minSpoken = Duration(milliseconds: 300);

  /// Requests of this visit, newest first (at most [_maxTurns]).
  List<TinyIslandTurn> get turns => List.unmodifiable(_turns);
  final List<TinyIslandTurn> _turns = [];
  static const _maxTurns = 20;

  TinyIslandTurn? get lastTurn => _turns.firstOrNull;

  /// How many actions the Decider chooses among: every one, every time.
  int get optionCount => _decider?.options.length ?? catalog.length;

  IslandAction? actionFor(String id) => _byId[id];

  /// Actions sent to the island and not finished yet (the one playing and
  /// those queued behind it), shrugs included.
  int get playing => _playing;
  int _playing = 0;

  /// How many may wait for the island before new requests are refused.
  static const maxQueued = 4;

  /// The island's last remark about an action, which may be an earlier
  /// turn's ("open(chest): The chest is already open."); null until there
  /// is one.
  String? get lastNote => _lastNote;
  String? _lastNote;

  /// The scene has loaded: requests can be sent once the Decider is ready.
  void sceneLoaded() => _set(() => _sceneReady = true);

  /// The scene did not load, or stopped drawing: requests stay disabled.
  void sceneFailed(String message) => _set(() {
    _sceneReady = false;
    _sceneError = message;
  });

  /// Reads the active model and prepares the Decider: the stored one when
  /// it fits this model and catalog, else a fresh fit. Called again after
  /// the user chose another model, and by "Try again".
  Future<void> open() {
    final generation = ++_generation;
    _cancel?.cancel('A newer open of the Tiny Island screen replaced it.');
    final cancel = _cancel = CancelToken();
    return _lane.run(() => _open(generation, cancel));
  }

  /// Runs in the lane: nothing else acquires or releases the embedder
  /// meanwhile.
  Future<void> _open(int generation, CancelToken cancel) async {
    if (_stale(generation)) return;
    // What an earlier open of this screen holds.
    await _release();
    _set(() {
      _status = TinyIslandStatus.loading;
      _error = null;
      _suggestModelList = false;
      // Another model may have been chosen: nothing of the last one shows.
      _embedderName = null;
      _backend = null;
      _prepared = 0;
      _preparedOf = 0;
      _prepareNote = null;
      _voiceStatus = TinyIslandVoiceStatus.off;
      _voiceNote = null;
      _voiceRecipe = null;
      _voicePrepared = 0;
      _voicePreparedOf = 0;
    });
    try {
      final setup = await _deps.readSetup();
      if (_stale(generation)) return;
      final TinyIslandEmbedderSetup ready;
      switch (setup) {
        case TinyIslandSetupProblem(:final message, :final modelListHelps):
          _set(() {
            _status = TinyIslandStatus.failed;
            _error = message;
            _suggestModelList = modelListHelps;
          });
          return;
        case final TinyIslandEmbedderSetup s:
          ready = s;
      }
      _set(() => _embedderName = ready.embedderName);
      final watch = Stopwatch()..start();
      final embedder = await _deps.loadEmbedder(ready);
      // Ours from here: released by the next open or by dispose, or below
      // when this open is already superseded.
      _embedder = embedder;
      if (_stale(generation)) {
        await _release();
        return;
      }
      _set(() => _backend = embedder.activeBackend?.name);
      debugPrint(
        '[TinyIsland] embedder ${ready.embedderName} on '
        '${_backend ?? 'an unreported backend'}',
      );
      final prepared = await _deps.prepare(
        embedder: embedder,
        model: ready.model,
        recipe: _recipe,
        store: _deps.store,
        embedderId: _deps.embedderId,
        cancelToken: cancel,
        onProgress: (done, total) {
          if (_stale(generation)) return;
          _set(() {
            _status = TinyIslandStatus.preparing;
            _prepared = done;
            _preparedOf = total;
          });
        },
      );
      if (_stale(generation)) {
        await prepared.decider.close();
        await _release();
        return;
      }
      _decider = prepared.decider;
      final note = _describePreparation(prepared);
      debugPrint(
        '[TinyIsland] Decider ready: ${prepared.decider.options.length} '
        'options, $calibrationLabel, $note, ${watch.elapsedMilliseconds} ms',
      );
      _set(() {
        _prepareTime = watch.elapsed;
        _prepareNote = note;
        _status = TinyIslandStatus.ready;
      });
      if (ready.voiceProblem case final problem?) {
        _set(() => _voiceNote = problem);
      } else {
        final recipe = _voiceRecipe = _deps.voiceRecipe(
          catalog,
          threshold: ready.voiceThreshold,
        );
        await _prepareVoice(generation, cancel, embedder, ready.model, recipe);
      }
    } catch (e, st) {
      if (_stale(generation)) {
        await _release();
        return;
      }
      debugPrint('[TinyIsland] open failed: $e\n$st');
      _set(() {
        _status = TinyIslandStatus.failed;
        _error = _describe(e);
        _suggestModelList =
            e is EmbeddingLoadException || e is DeciderSpaceMismatchException;
      });
    }
  }

  /// Prepares the decider for spoken requests on [embedder], once typed
  /// requests already work: the stored one or a fresh fit, filed apart from
  /// the typed one. A failure turns speaking off and leaves typing alone.
  Future<void> _prepareVoice(
    int generation,
    CancelToken cancel,
    EmbeddingModel embedder,
    String model,
    IslandDeciderRecipe recipe,
  ) async {
    _set(() => _voiceStatus = TinyIslandVoiceStatus.preparing);
    try {
      final prepared = await _deps.prepare(
        embedder: embedder,
        model: '$model-voice',
        recipe: recipe,
        store: _deps.store,
        embedderId: _deps.embedderId,
        cancelToken: cancel,
        onProgress: (done, total) {
          if (_stale(generation)) return;
          _set(() {
            _voicePrepared = done;
            _voicePreparedOf = total;
          });
        },
      );
      if (_stale(generation)) {
        await prepared.decider.close();
        await _release();
        return;
      }
      _voiceDecider = prepared.decider;
      final note = _describePreparation(prepared);
      debugPrint(
        '[TinyIsland] voice Decider ready: $voiceCalibrationLabel, $note',
      );
      _set(() {
        _voiceStatus = TinyIslandVoiceStatus.ready;
        _voiceNote = note;
      });
    } catch (e, st) {
      if (_stale(generation)) {
        await _release();
        return;
      }
      debugPrint('[TinyIsland] preparing the voice Decider failed: $e\n$st');
      _set(() {
        _voiceStatus = TinyIslandVoiceStatus.failed;
        _voiceNote = 'preparing it failed: ${_describe(e)}';
      });
    }
  }

  String _describePreparation(PreparedIslandDecider p) {
    final where = _deps.store.where;
    return [
      if (p.loaded)
        'loaded from $where'
      else if (p.refitReason case final reason?)
        'fitted again because $reason'
      else
        'fitted on this device',
      if (!p.loaded && p.stored) 'stored in $where',
      if (p.storeProblem case final problem?)
        p.stored ? problem : '$problem: the next visit fits it again',
    ].join('; ');
  }

  /// Decides [request] and plays the result: the chosen action, or a shrug
  /// when the Decider abstains.
  Future<void> submit(String request) async {
    final text = request.trim();
    final decider = _decider;
    if (text.isEmpty || !canSend || decider == null) return;
    await _decide(
      TinyIslandTurn(text),
      decider,
      DeciderInput(EmbeddingInput.text(text)),
    );
  }

  /// The mic button is pressed: starts recording a spoken request.
  Future<void> startListening() async {
    if (!canSpeak) return;
    final recorder = _recorder ??= _deps.recorder!();
    _set(() {
      _listening = true;
      _error = null;
    });
    final recording = _recording = recorder.start();
    try {
      await recording;
    } catch (e, st) {
      debugPrint('[TinyIsland] the microphone did not start: $e\n$st');
      _set(() {
        _listening = false;
        _error = 'The microphone did not start: ${_describe(e)}';
      });
    }
  }

  /// The mic button is released: stops recording and decides what was said.
  Future<void> stopListening() async {
    final recorder = _recorder;
    if (!_listening || recorder == null) return;
    _set(() => _listening = false);
    final Uint8List? wav;
    try {
      // A recorder still starting is stopped once it has started.
      await _recording;
      wav = await recorder.stop();
    } catch (e, st) {
      debugPrint('[TinyIsland] the recording failed: $e\n$st');
      _set(() => _error = 'The recording failed: ${_describe(e)}');
      return;
    }
    if (wav == null) {
      _set(() => _error = 'Nothing was recorded.');
      return;
    }
    await submitSpoken(wav);
  }

  /// Decides the spoken request [wav] (a WAV file) with the decider for
  /// spoken requests, and plays the result as [submit] does. The mic button
  /// ends here; tests and the demo recording hand it a clip directly.
  Future<void> submitSpoken(Uint8List wav) async {
    final decider = _voiceDecider;
    if (!canSend || decider == null) return;
    final Duration length;
    try {
      length = islandWavDuration(wav);
    } on ArgumentError catch (e) {
      _set(() => _error = 'The recording is not a WAV file: ${e.message}');
      return;
    }
    if (length < minSpoken) {
      _set(() => _error = 'Hold the mic while you speak, then let go.');
      return;
    }
    final seconds = (length.inMilliseconds / 1000).toStringAsFixed(1);
    await _decide(
      TinyIslandTurn('spoken request, $seconds s', spoken: length),
      decider,
      DeciderInput(EmbeddingInput.audio(wav)),
    );
  }

  Future<void> _decide(
    TinyIslandTurn turn,
    Decider decider,
    DeciderInput input,
  ) async {
    final text = turn.request;
    _set(() {
      _deciding = true;
      _error = null;
      _turns.insert(0, turn);
      if (_turns.length > _maxTurns) _turns.removeLast();
    });
    final DeciderAnswer answer;
    try {
      answer = await decider.choose(input);
    } catch (e, st) {
      debugPrint('[TinyIsland] deciding "$text" failed: $e\n$st');
      // A closed embedder (core could not serve another), a decider error
      // or a closed decider leaves nothing to decide with: the screen
      // fails, and "Try again" opens a fresh one. Anything else (an input
      // the model refuses) belongs to this request alone.
      final broken =
          e is EmbedderClosedException ||
          e is DeciderException ||
          e is StateError ||
          decider.isClosed;
      _set(() {
        turn.error = _describe(e);
        if (broken &&
            (identical(_decider, decider) ||
                identical(_voiceDecider, decider))) {
          _status = TinyIslandStatus.failed;
          _error = 'The Decider stopped working: ${_describe(e)}';
          _suggestModelList = e is DeciderSpaceMismatchException;
        }
      });
      return;
    } finally {
      _set(() => _deciding = false);
    }
    final best = answer.ranked.firstOrNull;
    debugPrint(
      '[TinyIsland] "$text" -> '
      '${answer.choice ?? 'abstained (${answer.abstainReason?.name})'} '
      '${best == null ? '-' : '${answer.scoreKind.name} ${best.score.toStringAsFixed(3)}'} '
      'in ${(answer.provenance.encodeTime + answer.provenance.scoreTime).inMicroseconds / 1000} ms',
    );
    final action = switch (answer.choice) {
      final id? => _byId[id],
      null => null,
    };
    _set(() {
      turn.answer = answer;
      turn.action = action;
      if (answer.choice != null && action == null) {
        turn.error =
            'The Decider chose "${answer.choice}", which is not an island '
            'action.';
      } else if (_playing >= maxQueued) {
        // A decision is instant, an animation is not: past a few queued
        // ones the island would lag far behind what the HUD shows.
        turn.error =
            'The island is still playing $_playing actions; '
            '${action?.id ?? 'the shrug'} was not queued.';
      }
    });
    if (_disposed || turn.error != null) return;
    _set(() => _playing++);
    try {
      if (action == null) {
        await _stage.shrug();
        return;
      }
      final outcome = await _stage.perform(action);
      _set(() {
        turn.outcome = outcome;
        if (outcome.note case final note?) _lastNote = '${action.id}: $note';
      });
    } catch (e, st) {
      if (_disposed) return;
      final what = action?.id ?? 'the shrug';
      debugPrint('[TinyIsland] playing $what failed: $e\n$st');
      _set(() {
        turn.error = 'The island could not play $what: $e';
        _lastNote = '$what: could not play it ($e)';
      });
    } finally {
      _set(() => _playing--);
    }
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  /// Closes what this screen holds: the decider, then the embedder. Runs in
  /// the lane (from [_open] or [dispose]). A failed close is logged; it
  /// never replaces the error the screen shows.
  Future<void> _release() async {
    final deciders = [?_decider, ?_voiceDecider];
    final embedder = _embedder;
    _decider = null;
    _voiceDecider = null;
    _embedder = null;
    for (final decider in deciders) {
      try {
        await decider.close();
      } catch (e, st) {
        debugPrint('[TinyIsland] closing a Decider failed: $e\n$st');
      }
    }
    if (embedder != null) {
      try {
        await embedder.close();
      } catch (e, st) {
        debugPrint('[TinyIsland] closing the embedder failed: $e\n$st');
      }
    }
  }

  static String _describe(Object error) => switch (error) {
    EmbeddingException(:final message) => '${error.runtimeType}: $message',
    DeciderException(:final message) => '${error.runtimeType}: $message',
    StateError(:final message) => message,
    ArgumentError(:final message) => '$message',
    _ => '$error',
  };

  void _set(void Function() change) {
    change();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel('The Tiny Island screen was closed.');
    if (_recorder case final recorder?) {
      unawaited(
        recorder.dispose().catchError((Object e, StackTrace st) {
          debugPrint('[TinyIsland] releasing the microphone failed: $e\n$st');
        }),
      );
    }
    // dispose() cannot await: the release waits its turn in the lane, so a
    // newer screen asks core for the embedder only after it is closed.
    unawaited(
      _lane.run(_release).catchError((Object e, StackTrace st) {
        debugPrint('[TinyIsland] releasing the embedder failed: $e\n$st');
      }),
    );
    super.dispose();
  }
}
