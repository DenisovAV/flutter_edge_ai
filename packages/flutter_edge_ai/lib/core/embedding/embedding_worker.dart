// Long-lived background isolate that drives a runtime-agnostic
// [EmbeddingForwardPass] (built from a [ForwardPassDescriptor]'s top-level
// factory tear-off — see `forward_pass.dart`) plus tokenization, which comes
// from a registered `EmbeddingTokenizerProvider` (`flutter_edge_ai_embeddings`). Generalization of what used to be
// `litert/litert_embedding_worker.dart`; the isolate machinery below
// (message classes, id-correlated pending map, onExit-null death handling,
// log-level seeding, debugName) comes from that file.
//
// Close never kills the isolate. It used to wait five seconds for an ack and
// then `Isolate.kill` — but the worker served requests one `await for` turn at
// a time, so a close sent behind a batch waited for the whole batch, the five
// seconds ran out, and the kill landed before the worker's `finally` could
// call `pass.close()`. A killed isolate runs no more Dart code, so the native
// model stayed resident for the life of the process. Now the worker queues
// requests itself and serves one at a time, so a close fails everything that
// has not started, lets the one call in flight finish, closes the forward pass
// and exits on its own.
//
// Why a long-lived worker and not `Isolate.run` per call:
//   - A real forward pass costs hundreds of ms to load/compile but far less
//     to run per call, so it MUST be loaded once and reused — `Isolate.run`
//     would reload every call.
//   - FFI `Pointer`/`DynamicLibrary` cannot cross isolate boundaries
//     (flutter/flutter#169431; passing a pointer as an int is officially
//     "risky and unsupported"). Keeping all handles inside the one worker
//     means nothing crosses the boundary, and a (future) GPU command queue —
//     which is thread-affine — is created and used on the same isolate.
//
// Only sendable values cross the port: the [ForwardPassDescriptor] + paths
// (setup), text + task-type prefix (request), and `List<double>` vectors
// (reply).

import 'dart:async';
import 'dart:collection';

import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

import 'dart:isolate';

import 'forward_pass.dart';
import 'pooling.dart';
import 'tokenizer_adapter.dart';

/// Handshake payload the worker sends back once the forward pass is loaded.
class _Ready {
  _Ready(this.commandPort, this.seqLen, this.dim);
  final SendPort commandPort;
  final int seqLen;
  final int dim;
}

/// Request: embed [text] with the given task-type [prefix]. [id] correlates
/// the reply.
class _EmbedRequest {
  _EmbedRequest(this.id, this.text, this.prefix);
  final int id;
  final String text;
  final String prefix;
}

/// Reply carrying the embedding vector (or an error message).
class _EmbedReply {
  _EmbedReply(this.id, this.vector, this.error);
  final int id;
  final List<double>? vector;
  final String? error;
}

/// Sentinel asking the worker to stop: fail every request that has not
/// started, let the one in flight finish, close the forward pass, ack, exit.
class _Close {
  const _Close();
}

/// The worker's last message, sent through `Isolate.exit` once
/// [EmbeddingForwardPass.close] has returned — so nothing of the worker runs
/// after it. [error] is set when that close threw: the native model may then
/// still be resident, and the main isolate says so.
class _CloseAck {
  const _CloseAck(this.error);
  final String? error;
}

/// The error a request gets when the worker closed before it started.
const _closedBeforeRunMessage =
    'EmbeddingWorker closed before this request ran';

/// Parameters needed to boot the worker isolate. Must be fully sendable —
/// [descriptor] carries a top-level factory tear-off (see
/// `ForwardPassDescriptor`'s doc for why that's the one form of "code
/// reference" that survives `Isolate.spawn`).
class _WorkerInit {
  _WorkerInit({
    required this.replyTo,
    required this.descriptor,
    required this.tokenizerPath,
    required this.logLevel,
  });
  final SendPort replyTo;
  final ForwardPassDescriptor descriptor;
  final String tokenizerPath;

  /// Snapshot of the main-isolate [edgeAiLogLevel] at spawn — the worker
  /// isolate gets its own copy of the per-isolate top-level (default info),
  /// so it must be seeded explicitly or its logs ignore the caller's level.
  final EdgeAiLogLevel logLevel;
}

/// Main-isolate handle to the embedding worker. Spawns the isolate, performs
/// the load handshake, and multiplexes concurrent requests by id.
class EmbeddingWorker {
  EmbeddingWorker._(
    this._commandPort,
    this._fromWorker,
    this.inputSequenceLength,
    this.outputDimension,
  );

  /// How long [close] waits before saying it is still waiting. It keeps
  /// waiting afterwards: the only way to stop sooner is to kill the isolate,
  /// and a killed isolate never frees its native model.
  static const _slowCloseNotice = Duration(seconds: 30);

  final SendPort _commandPort;
  final ReceivePort _fromWorker;

  /// Sequence length the forward pass reported at load, or -1 if the engine
  /// has none to report (see [EmbeddingForwardPass.inputSequenceLength]).
  final int inputSequenceLength;

  /// Output embedding dimension.
  final int outputDimension;

  final _pending = <int, Completer<List<double>>>{};
  int _nextId = 0;

  /// True from the moment [close] is called, or the worker dies; [embed]
  /// refuses from then on.
  bool _closing = false;

  /// Completes when the worker is gone: its [_CloseAck], or its onExit.
  final _gone = Completer<void>();

  /// The one teardown every [close] call shares.
  Future<void>? _closeFuture;

  /// Spawn the worker and wait until the forward pass is loaded.
  static Future<EmbeddingWorker> spawn({
    required ForwardPassDescriptor descriptor,
    required String tokenizerPath,
  }) async {
    final fromWorker = ReceivePort();
    final readyCompleter = Completer<_Ready>();

    // First message from the worker is either _Ready or a String error. A
    // `null` is the isolate's onExit signal — if it arrives before _Ready, the
    // worker died during load (e.g. a native crash compiling a corrupt model),
    // so fail the completer instead of hanging forever.
    late final StreamSubscription<dynamic> sub;
    sub = fromWorker.listen((msg) {
      if (msg is _Ready) {
        readyCompleter.complete(msg);
      } else if (msg is String) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(StateError(msg));
        }
      } else if (msg == null) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(
            StateError('Embedding worker isolate exited during load'),
          );
        }
      }
    });

    final _Ready ready;
    try {
      await Isolate.spawn(
        _workerEntry,
        _WorkerInit(
          replyTo: fromWorker.sendPort,
          descriptor: descriptor,
          tokenizerPath: tokenizerPath,
          logLevel: edgeAiLogLevel,
        ),
        // onExit posts `null` to fromWorker so we never wait on a dead isolate.
        onExit: fromWorker.sendPort,
        debugName: 'embedding-forward-worker',
      );
      ready = await readyCompleter.future;
    } catch (_) {
      // Nothing to kill. A worker that fails to load closes whatever forward
      // pass it built and leaves through `Isolate.exit` carrying the error, and
      // the onExit `null` means it is already gone. Killing it here instead
      // could land before that close — the leak [close] no longer has.
      await sub.cancel();
      fromWorker.close();
      rethrow;
    }

    final worker = EmbeddingWorker._(
      ready.commandPort,
      fromWorker,
      ready.seqLen,
      ready.dim,
    );
    // Re-point the subscription at the steady-state reply handler.
    sub.onData(worker._onReply);
    return worker;
  }

  void _onReply(dynamic msg) {
    if (msg is _EmbedReply) {
      final completer = _pending.remove(msg.id);
      if (completer == null) return;
      if (msg.error != null) {
        completer.completeError(StateError(msg.error!));
      } else {
        completer.complete(msg.vector!);
      }
    } else if (msg is _CloseAck) {
      final error = msg.error;
      if (error != null) {
        _warn(
          'the embedding forward pass failed to close; its native model may '
          'still be resident: $error',
        );
      }
      if (!_gone.isCompleted) _gone.complete();
    } else if (msg == null) {
      // onExit. After a _CloseAck the port is already closed, so this only
      // arrives when the worker died without one — a native crash in a request
      // or in its own teardown. Fail every in-flight request rather than leave
      // callers hanging.
      _closing = true;
      _failAllPending(
        _closeFuture == null
            ? 'Embedding worker isolate exited unexpectedly'
            : 'Embedding worker isolate exited while closing',
      );
      _fromWorker.close();
      if (!_gone.isCompleted) _gone.complete();
    }
  }

  void _failAllPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
    _pending.clear();
  }

  /// Embed one text. The forward runs in the worker; the UI isolate stays free.
  Future<List<double>> embed(String text, {required String prefix}) {
    if (_closing) {
      return Future.error(StateError('EmbeddingWorker is closed'));
    }
    final id = _nextId++;
    final completer = Completer<List<double>>();
    _pending[id] = completer;
    _commandPort.send(_EmbedRequest(id, text, prefix));
    return completer.future;
  }

  /// Stops the worker without abandoning its native model.
  ///
  /// Requests that have not started fail with a "closed" [StateError]. The one
  /// in flight — the worker serves one at a time — finishes and gets its
  /// vector. Then the worker closes the forward pass, acks and exits, and this
  /// returns.
  ///
  /// It waits for all of that however long the call in flight takes, and
  /// never kills the isolate: a killed isolate runs no more Dart code, so its
  /// forward pass is never closed and the native model stays resident for the
  /// life of the process. After [_slowCloseNotice] it says what it is waiting
  /// for, once.
  ///
  /// Idempotent; concurrent callers share one teardown.
  Future<void> close() => _closeFuture ??= _shutDown();

  Future<void> _shutDown() async {
    _closing = true;
    if (!_gone.isCompleted) {
      _commandPort.send(const _Close());
      final notice = Timer(
        _slowCloseNotice,
        () => _warn(
          'EmbeddingWorker.close() has waited '
          '${_slowCloseNotice.inSeconds} s for the worker to finish the '
          'embedding request in flight and close its native model. It keeps '
          'waiting rather than kill the worker, because a killed worker never '
          'frees its native model.',
        ),
      );
      try {
        await _gone.future;
      } finally {
        notice.cancel();
      }
    }
    _fromWorker.close();
    // The worker answers every request it received before it acks, and the
    // port delivers in order, so this is empty — unless the worker died, and
    // then onExit has already failed them. A net, not a path.
    _failAllPending(_closedBeforeRunMessage);
  }

  /// `print`, not [edgeAiLog], for the reason `EmbedderCache` gives: edgeAiLog
  /// is silent in release, and release is where a leaked native model or a
  /// hung close gets debugged. Both are abnormal, so this costs nothing in the
  /// normal case.
  static void _warn(String message) {
    // ignore: avoid_print
    print('[flutter_edge_ai] WARNING: $message');
  }
}

/// Turns a raw [ForwardResult] into the final embedding vector per
/// [contract] (design D-T2: `pass.outputContract ?? descriptor.outputContract`
/// — resolved by the caller). `pooledFinal` copies verbatim — see
/// [EmbeddingOutputContract.pooledFinal]'s doc for why this must never fall
/// through to [meanPoolAndNormalize]. `tokenLevel` uses [attentionMask] —
/// the *effective* mask (design D-T3: [ForwardResult.attentionMask] if the
/// pass echoed one, else the request's mask) — so padding a pass added never
/// leaks into the mean.
List<double> _finalize(
  EmbeddingOutputContract contract,
  ForwardResult result,
  List<int>? attentionMask,
) {
  switch (contract) {
    case EmbeddingOutputContract.pooledFinal:
      return _copyPooledFinal(result);
    case EmbeddingOutputContract.tokenLevel:
      return meanPoolAndNormalize(result, attentionMask: attentionMask);
  }
}

/// Copies a `pooledFinal` [ForwardResult] verbatim — but only after
/// confirming it actually IS an already-pooled `[1, dim]` vector. Symmetric
/// to [meanPoolAndNormalize]'s rank guard in `pooling.dart`: without this,
/// a token-level `[1, seq, dim]` result misrouted here (e.g. an ONNX output
/// name the engine's dispatch didn't recognize, silently falling back to
/// "assume pooled") would be flattened and returned as a corrupt vector —
/// unpooled, unnormalized, and the wrong length — with no error anywhere.
List<double> _copyPooledFinal(ForwardResult result) {
  final shape = result.shape;
  final isPooledShape =
      shape.length == 2 && shape[0] == 1 && result.values.length == shape[1];
  if (!isPooledShape) {
    throw StateError(
      'EmbeddingOutputContract.pooledFinal requires a rank-2 `[1, dim]` '
      'already-pooled result; got shape $shape with ${result.values.length} '
      'values. This usually means a token-level output was misclassified as '
      'pooled (e.g. an unrecognized ONNX output name falling back to '
      '"assume pooled") — copying it verbatim would silently return a '
      'corrupt, unpooled embedding.',
    );
  }
  return List<double>.of(result.values);
}

/// Closes [pass], reporting a failure as text instead of throwing, so the
/// caller still sends its last message. Null means it closed cleanly.
Future<String?> _closePass(EmbeddingForwardPass pass) async {
  try {
    await pass.close();
    return null;
  } catch (e, st) {
    edgeAiLog('[EmbeddingWorker] forward pass close failed: $e\n$st');
    return '$e';
  }
}

/// Isolate entry point. Loads the tokenizer + forward pass, then serves
/// requests until _Close.
Future<void> _workerEntry(_WorkerInit init) async {
  // Seed this isolate's per-isolate log level from the main-isolate snapshot.
  edgeAiLogLevel = init.logLevel;

  final EmbeddingTokenizer tokenizer;
  final EmbeddingForwardPass pass;
  final int seqLen;
  final int dim;
  // Nullable twin of `pass`, so the failure path can tell "never built" from
  // "built, then failed" — and close the second.
  EmbeddingForwardPass? built;
  try {
    tokenizer = await init.descriptor.tokenizerFactory(init.tokenizerPath);
    built = init.descriptor.factory(init.descriptor.modelPath);
    await built.load();
    // Read inside the try: a getter that throws is a failed load too, and
    // the pass is open by now.
    seqLen = built.inputSequenceLength ?? -1;
    dim = built.outputDimension;
    pass = built;
  } catch (e, st) {
    edgeAiLog('[EmbeddingWorker] load failed: $e\n$st');
    // A pass that was constructed may hold native handles whatever stage it
    // failed at; `close()` is idempotent by contract, so it is always called.
    // Closed BEFORE the error is sent — the main isolate gives up on this
    // worker the moment the error arrives.
    final closeError = built == null ? null : await _closePass(built);
    Isolate.exit(
      init.replyTo,
      closeError == null
          ? 'Embedding worker failed to load: $e'
          : 'Embedding worker failed to load: $e (closing the forward pass '
                'also failed, so its native model may still be resident: '
                '$closeError)',
    );
  }

  edgeAiLog(
    '[EmbeddingWorker] loaded: engine=${init.descriptor.engineTag}, '
    'seqLen=$seqLen, dim=$dim',
  );

  final commandPort = ReceivePort();
  final queued = Queue<_EmbedRequest>();
  var closeRequested = false;
  Completer<void>? wake;

  // The listener only files messages; the loop below does the work. That
  // split is what lets a close overtake a queue: the listener sees _Close as
  // soon as the event loop is free, not after every request ahead of it ran.
  commandPort.listen((msg) {
    if (msg is _EmbedRequest) {
      queued.add(msg);
    } else if (msg is _Close) {
      closeRequested = true;
      commandPort.close();
      // Only what has not started. The request in flight, if any, was taken
      // off the queue when it started, and it finishes on its own terms.
      while (queued.isNotEmpty) {
        final request = queued.removeFirst();
        init.replyTo.send(
          _EmbedReply(request.id, null, _closedBeforeRunMessage),
        );
      }
    }
    final waiting = wake;
    wake = null;
    waiting?.complete();
  });

  init.replyTo.send(_Ready(commandPort.sendPort, seqLen, dim));

  final String? closeError;
  try {
    // One request in flight at a time, in arrival order.
    while (!closeRequested) {
      if (queued.isEmpty) {
        final idle = wake = Completer<void>();
        await idle.future;
        continue;
      }
      // Yield to the event loop before every request. A forward pass may
      // block this isolate inside a synchronous native call, so a _Close sent
      // meanwhile is still in the message queue when the call returns — and
      // awaiting a completed future only drains microtasks, never that queue.
      // A zero-duration timer is posted to the BACK of the same queue, so by
      // the time it fires the listener has filed the close and emptied
      // `queued`.
      await Future<void>.delayed(Duration.zero);
      if (closeRequested || queued.isEmpty) continue;
      await _serve(queued.removeFirst(), tokenizer, pass, init);
    }
  } finally {
    // Also on an unexpected throw out of the loop: the native model is freed
    // either way, and the throw then takes the isolate down, which the main
    // isolate's onExit handling reports.
    closeError = await _closePass(pass);
  }
  // Ack and exit in one step: nothing of this worker runs after the ack, so
  // the main isolate never has to kill it.
  Isolate.exit(init.replyTo, _CloseAck(closeError));
}

/// Runs one request and replies — with the vector, or with the error. Never
/// throws, so one bad input cannot stop the loop that serves the rest.
Future<void> _serve(
  _EmbedRequest msg,
  EmbeddingTokenizer tokenizer,
  EmbeddingForwardPass pass,
  _WorkerInit init,
) async {
  try {
    final tokenized = tokenizer.encode(msg.prefix, msg.text);
    final result = await pass.run(
      tokenIds: tokenized.ids,
      attentionMask: tokenized.attentionMask,
      tokenTypeIds: tokenized.tokenTypeIds,
    );
    final contract = pass.outputContract ?? init.descriptor.outputContract;
    final effectiveMask = result.attentionMask ?? tokenized.attentionMask;
    final vector = _finalize(contract, result, effectiveMask);
    init.replyTo.send(_EmbedReply(msg.id, vector, null));
  } catch (e) {
    init.replyTo.send(_EmbedReply(msg.id, null, e.toString()));
  }
}
