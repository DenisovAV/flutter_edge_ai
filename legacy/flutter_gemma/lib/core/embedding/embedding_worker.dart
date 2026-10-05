// Long-lived background isolate that drives a runtime-agnostic
// [EmbeddingForwardPass] (built from a [ForwardPassDescriptor]'s top-level
// factory tear-off — see `forward_pass.dart`) plus tokenization, which comes
// from a registered `EmbeddingTokenizerProvider` (`flutter_gemma_embeddings`). Generalization of what used to be
// `litert/litert_embedding_worker.dart`; the isolate machinery below
// (message classes, id-correlated pending map, onExit-null death handling,
// timeout-guarded close, log-level seeding, debugName) is preserved
// verbatim from that file.
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
import 'package:flutter_gemma/core/utils/gemma_log.dart';
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

/// Sentinel asking the worker to tear down the forward pass and exit.
class _Close {
  const _Close();
}

/// Ack the worker sends after [EmbeddingForwardPass.close] completes, so the
/// main isolate can kill the isolate without racing native teardown.
class _CloseAck {
  const _CloseAck();
}

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

  /// Snapshot of the main-isolate [gemmaLogLevel] at spawn — the worker
  /// isolate gets its own copy of the per-isolate top-level (default info),
  /// so it must be seeded explicitly or its logs ignore the caller's level.
  final GemmaLogLevel logLevel;
}

/// Main-isolate handle to the embedding worker. Spawns the isolate, performs
/// the load handshake, and multiplexes concurrent requests by id.
class EmbeddingWorker {
  EmbeddingWorker._(
    this._isolate,
    this._commandPort,
    this._fromWorker,
    this.inputSequenceLength,
    this.outputDimension,
  );

  final Isolate _isolate;
  final SendPort _commandPort;
  final ReceivePort _fromWorker;

  /// Sequence length the forward pass reported at load, or -1 if the engine
  /// has none to report (see [EmbeddingForwardPass.inputSequenceLength]).
  final int inputSequenceLength;

  /// Output embedding dimension.
  final int outputDimension;

  final _pending = <int, Completer<List<double>>>{};
  int _nextId = 0;
  bool _closed = false;
  Completer<void>? _closeAck;

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
    late final StreamSubscription sub;
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

    final isolate = await Isolate.spawn(
      _workerEntry,
      _WorkerInit(
        replyTo: fromWorker.sendPort,
        descriptor: descriptor,
        tokenizerPath: tokenizerPath,
        logLevel: gemmaLogLevel,
      ),
      // onExit posts `null` to fromWorker so we never wait on a dead isolate.
      onExit: fromWorker.sendPort,
      debugName: 'embedding-forward-worker',
    );

    final _Ready ready;
    try {
      ready = await readyCompleter.future;
    } catch (_) {
      await sub.cancel();
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }

    final worker = EmbeddingWorker._(
      isolate,
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
      _closeAck?.complete();
    } else if (msg == null) {
      // onExit: the worker isolate died. If this is part of a normal close,
      // the ack path already handled it; otherwise it's an unexpected crash —
      // fail every in-flight request rather than leave callers hanging.
      _failAllPending('Embedding worker isolate exited unexpectedly');
      _closed = true;
      _closeAck?.complete();
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
    if (_closed) {
      return Future.error(StateError('EmbeddingWorker is closed'));
    }
    final id = _nextId++;
    final completer = Completer<List<double>>();
    _pending[id] = completer;
    _commandPort.send(_EmbedRequest(id, text, prefix));
    return completer.future;
  }

  /// Tear down the forward pass and stop the isolate. Waits for the worker to
  /// finish native teardown (a _CloseAck, or the isolate's onExit) before
  /// killing it, so handles are never freed mid-dispose.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeAck = Completer<void>();
    _commandPort.send(const _Close());
    // Wait for the worker's dispose ack / exit; cap the wait so a wedged
    // native teardown can't hang close() forever.
    try {
      await _closeAck!.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Timed out or errored — fall through to a forced kill below.
    }
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _failAllPending('EmbeddingWorker closed mid-request');
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

/// Isolate entry point. Loads the tokenizer + forward pass, then serves
/// requests until _Close.
Future<void> _workerEntry(_WorkerInit init) async {
  // Seed this isolate's per-isolate log level from the main-isolate snapshot.
  gemmaLogLevel = init.logLevel;

  final EmbeddingTokenizer tokenizer;
  final EmbeddingForwardPass pass;
  try {
    tokenizer = await init.descriptor.tokenizerFactory(init.tokenizerPath);
    pass = init.descriptor.factory(init.descriptor.modelPath);
    await pass.load();
  } catch (e, st) {
    gemmaLog('[EmbeddingWorker] load failed: $e\n$st');
    init.replyTo.send('Embedding worker failed to load: $e');
    return;
  }

  gemmaLog(
    '[EmbeddingWorker] loaded: engine=${init.descriptor.engineTag}, '
    'seqLen=${pass.inputSequenceLength}, dim=${pass.outputDimension}',
  );

  final commandPort = ReceivePort();
  init.replyTo.send(
    _Ready(
      commandPort.sendPort,
      pass.inputSequenceLength ?? -1,
      pass.outputDimension,
    ),
  );

  try {
    await for (final msg in commandPort) {
      if (msg is _EmbedRequest) {
        try {
          final tokenized = tokenizer.encode(msg.prefix, msg.text);
          final result = await pass.run(
            tokenIds: tokenized.ids,
            attentionMask: tokenized.attentionMask,
            tokenTypeIds: tokenized.tokenTypeIds,
          );
          final contract =
              pass.outputContract ?? init.descriptor.outputContract;
          final effectiveMask = result.attentionMask ?? tokenized.attentionMask;
          final vector = _finalize(contract, result, effectiveMask);
          init.replyTo.send(_EmbedReply(msg.id, vector, null));
        } catch (e) {
          init.replyTo.send(_EmbedReply(msg.id, null, e.toString()));
        }
      } else if (msg is _Close) {
        commandPort.close();
        break;
      }
    }
  } finally {
    // Always free native handles, even if the loop exits unexpectedly, then
    // ack so the main isolate can kill us without racing teardown.
    await pass.close();
    init.replyTo.send(const _CloseAck());
  }
}
