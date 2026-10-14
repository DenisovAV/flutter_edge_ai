// The Decider API is @experimental; Tiny Island is its demo.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'island_catalog.dart';
import 'island_decider_preparation.dart';
import 'island_decider_recipe.dart';
import 'island_stage.dart';
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

/// One request and what came of it. Written by the view model only.
final class TinyIslandTurn {
  TinyIslandTurn(this.request);

  final String request;

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

  IslandEmbedderLane get _lane => _deps.lane ?? islandEmbedderLane;

  EmbeddingModel? _embedder;
  Decider? _decider;
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
    final turn = TinyIslandTurn(text);
    _set(() {
      _deciding = true;
      _error = null;
      _turns.insert(0, turn);
      if (_turns.length > _maxTurns) _turns.removeLast();
    });
    final DeciderAnswer answer;
    try {
      answer = await decider.choose(DeciderInput(EmbeddingInput.text(text)));
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
        if (broken && identical(_decider, decider)) {
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
      'in ${(answer.provenance.embedTime + answer.provenance.scoreTime).inMicroseconds / 1000} ms',
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
    final decider = _decider;
    final embedder = _embedder;
    _decider = null;
    _embedder = null;
    if (decider != null) {
      try {
        await decider.close();
      } catch (e, st) {
        debugPrint('[TinyIsland] closing the Decider failed: $e\n$st');
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
