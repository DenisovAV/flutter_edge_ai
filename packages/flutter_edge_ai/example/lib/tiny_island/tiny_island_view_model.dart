import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show EmbeddingException, EmbeddingLoadException;

import 'island_catalog.dart';
import 'island_decider.dart';
import 'island_stage.dart';
import 'tiny_island_dependencies.dart';

enum TinyIslandStatus {
  /// Reading what is active and loading the embedder.
  loading,

  /// Embedding the catalog (first visit with this model and catalog).
  preparing,
  ready,
  failed,
}

/// One request and what came of it.
final class TinyIslandTurn {
  TinyIslandTurn(this.request);

  final String request;
  IslandDecision? decision;

  /// The chosen action; null while deciding, and when the decider abstained.
  IslandAction? action;

  /// What the stage did; null until it has finished.
  IslandOutcome? outcome;

  /// What failed, ready to show.
  String? error;
}

/// The Tiny Island screen's state: the Decider (EmbeddingGemma 2 over the
/// action catalog), the requests sent to it, and what the island did.
///
/// Every failure is kept in [error] (or in the turn it belongs to) for the
/// screen to show — never swallowed, and never replaced by a fallback.
final class TinyIslandViewModel extends ChangeNotifier {
  TinyIslandViewModel(this._deps, this._stage)
    : catalog = List.unmodifiable(_deps.catalog()) {
    _byId = {for (final action in catalog) action.id: action};
    if (_byId.length != catalog.length) {
      throw StateError('The island catalog repeats an action id.');
    }
  }

  final TinyIslandDependencies _deps;
  final IslandStage _stage;
  final List<IslandAction> catalog;
  late final Map<String, IslandAction> _byId;
  IslandDecider? _decider;
  bool _disposed = false;

  /// Bumped by every [open]: an older open that finishes late releases what
  /// it opened instead of installing it.
  int _generation = 0;

  TinyIslandStatus status = TinyIslandStatus.loading;

  /// What failed last, ready to show; null when nothing did.
  String? error;

  /// True when [error] is fixed by choosing another model on the list.
  bool suggestModelList = false;

  /// The active embedder's name, once read.
  String? embedderName;

  /// Catalog texts embedded so far while [status] is preparing.
  int prepared = 0;
  int preparedOf = 0;

  /// How long loading the model and preparing the catalog took.
  Duration? prepareTime;

  /// A request is being decided.
  bool deciding = false;

  /// Requests of this visit, newest first (at most [_maxTurns]).
  final List<TinyIslandTurn> turns = [];
  static const _maxTurns = 20;

  TinyIslandTurn? get lastTurn => turns.firstOrNull;

  String? get deciderName => _decider?.name;
  String? get backend => _decider?.backend;
  int get optionCount => _decider?.optionCount ?? catalog.length;

  IslandAction? actionFor(String id) => _byId[id];

  /// Reads the active model and prepares the Decider. Called again after the
  /// user chose another model.
  Future<void> open() {
    final generation = ++_generation;
    // One open at a time: the embedder is core's cached singleton, so an
    // older open releasing its model must finish before a newer one asks
    // for it, or the newer one would get the model being closed. A
    // superseded open that has not started yet does nothing.
    final run = _openLane.then((_) => _open(generation));
    _openLane = run.catchError((Object _) {});
    return run;
  }

  Future<void> _openLane = Future.value();

  Future<void> _open(int generation) async {
    if (_stale(generation)) return;
    final previous = _decider;
    _decider = null;
    _set(() {
      status = TinyIslandStatus.loading;
      error = null;
      suggestModelList = false;
      prepared = 0;
      preparedOf = 0;
    });
    try {
      await previous?.close();
      final setup = await _deps.readSetup();
      if (_stale(generation)) return;
      if (setup.problem case final problem?) {
        _set(() {
          status = TinyIslandStatus.failed;
          error = problem;
          suggestModelList = true;
        });
        return;
      }
      _set(() => embedderName = setup.embedderName);
      final watch = Stopwatch()..start();
      final decider = await _deps.openDecider(
        setup,
        catalog,
        onProgress: (done, total) {
          if (_stale(generation)) return;
          _set(() {
            status = TinyIslandStatus.preparing;
            prepared = done;
            preparedOf = total;
          });
        },
        isCancelled: () => _stale(generation),
      );
      if (_stale(generation)) {
        await decider.close();
        return;
      }
      _decider = decider;
      debugPrint(
        '[TinyIsland] Decider ready: ${decider.name} on '
        '${decider.backend ?? 'an unreported backend'}, '
        '${decider.optionCount} options, ${watch.elapsedMilliseconds} ms',
      );
      _set(() {
        prepareTime = watch.elapsed;
        status = TinyIslandStatus.ready;
      });
    } catch (e, st) {
      if (_stale(generation)) return;
      debugPrint('[TinyIsland] open failed: $e\n$st');
      _set(() {
        status = TinyIslandStatus.failed;
        error = _describe(e);
        suggestModelList = e is EmbeddingLoadException || e is StateError;
      });
    }
  }

  /// Decides [request] and plays the result: the chosen action, or a shrug
  /// when the Decider abstains.
  Future<void> submit(String request) async {
    final text = request.trim();
    final decider = _decider;
    if (text.isEmpty || deciding || decider == null) return;
    final turn = TinyIslandTurn(text);
    _set(() {
      deciding = true;
      error = null;
      turns.insert(0, turn);
      if (turns.length > _maxTurns) turns.removeLast();
    });
    final IslandDecision decision;
    try {
      decision = await decider.decide(text);
    } catch (e, st) {
      debugPrint('[TinyIsland] deciding "$text" failed: $e\n$st');
      _set(() {
        deciding = false;
        turn.error = _describe(e);
      });
      return;
    }
    debugPrint(
      '[TinyIsland] "$text" -> ${decision.choice ?? 'abstained (${decision.abstainReason?.name})'} '
      '${decision.ranked.first.score.toStringAsFixed(3)} in '
      '${decision.totalTime.inMicroseconds / 1000} ms',
    );
    final action = switch (decision.choice) {
      final id? => _byId[id],
      null => null,
    };
    _set(() {
      deciding = false;
      turn.decision = decision;
      turn.action = action;
      if (decision.choice != null && action == null) {
        turn.error =
            'The Decider chose "${decision.choice}", which is not '
            'an island action.';
      }
    });
    if (_disposed || turn.error != null) return;
    try {
      if (action == null) {
        await _stage.shrug();
      } else {
        final outcome = await _stage.perform(action);
        _set(() => turn.outcome = outcome);
      }
    } catch (e, st) {
      debugPrint('[TinyIsland] playing "${action?.id}" failed: $e\n$st');
      _set(() => turn.error = 'The island could not play it: $e');
    }
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  static String _describe(Object error) => switch (error) {
    EmbeddingException(:final message) => message,
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
    final decider = _decider;
    _decider = null;
    if (decider != null) {
      // dispose() cannot await; the close is logged if it fails.
      unawaited(
        decider.close().catchError((Object e, StackTrace st) {
          debugPrint('[TinyIsland] closing the Decider failed: $e\n$st');
        }),
      );
    }
    super.dispose();
  }
}
