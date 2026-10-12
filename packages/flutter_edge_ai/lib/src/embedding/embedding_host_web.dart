// The inline embedding host (R5 §4.5): the pass runs on the calling isolate —
// the web page on web, where there is no Isolate.spawn. Same RequestPump, same
// load check and failure encoding as the isolate host, so the web behaves like
// native: text before media, queued requests fail on close, the pass is
// closed once.
//
// Pure Dart (no dart:isolate): the VM tests run it. The one web-specific
// piece, the pump's per-request yield, comes through a conditional import —
// a MessageChannel message on the page, a zero timer everywhere else.

import 'dart:async';

import 'package:meta/meta.dart' show visibleForTesting;

import 'embedding_exceptions.dart';
import 'embedding_host.dart';
import 'embedding_input.dart';
import 'embedding_modality.dart';
import 'embedding_pass.dart';
import 'event_loop_yield.dart'
    if (dart.library.js_interop) 'event_loop_yield_web.dart';
import 'load_check.dart';
import 'request_lanes.dart';
import 'task_type.dart';
import 'wire.dart';

const _slowLoadNotice = Duration(seconds: 30);
const _slowCloseNotice = Duration(seconds: 30);

/// Builds [descriptor]'s pass, loads it and checks it against
/// [declaredMedia]; the conditional host entry point `CommonEmbeddingModel`
/// calls on web. [label] names the model file in messages.
///
/// Fails with `EmbeddingLoadException`. A pass whose load failed is closed
/// behind the error, not before it: a close that never returns must not hold
/// the caller, which may be the embedder cache's lane. [onFailedLoadCleanup]
/// receives, before the error is thrown, a future that ends when that close
/// has, so the caller can hold the next build until then.
Future<EmbeddingHost> startEmbeddingHost(
  EmbeddingPassDescriptor<Object> descriptor, {
  required Set<EmbeddingModality> declaredMedia,
  required String label,
  @visibleForTesting Duration slowLoadNotice = _slowLoadNotice,
  @visibleForTesting Duration slowCloseNotice = _slowCloseNotice,
  void Function(Future<void> cleanup)? onFailedLoadCleanup,
}) async {
  final engine = descriptor.engineTag;
  final EmbeddingPass pass;
  try {
    pass = descriptor.build();
  } catch (e, st) {
    Error.throwWithStackTrace(_loadFailure(e, engine), st);
  }
  final notice = Timer(
    slowLoadNotice,
    () => warnEmbeddingHost(
      'loading the $engine embedder for $label has taken '
      '${describeHostDuration(slowLoadNotice)} and is still running.',
    ),
  );
  try {
    final info = await pass.load();
    final modalities = checkLoadedPass(
      info,
      declaredMedia,
      engine: engine,
      label: label,
    );
    return _InlineEmbeddingHost(
      pass,
      info,
      modalities,
      engine: engine,
      label: label,
      slowCloseNotice: slowCloseNotice,
    );
  } catch (e, st) {
    final cleanup = _closeAfterFailedLoad(pass, engine, label, slowCloseNotice);
    onFailedLoadCleanup?.call(cleanup);
    unawaited(cleanup);
    Error.throwWithStackTrace(_loadFailure(e, engine), st);
  } finally {
    notice.cancel();
  }
}

EmbeddingException _loadFailure(Object error, String engine) =>
    EmbeddingFailure.fromError(
      error,
      engine: engine,
      loading: true,
      causeInMessage: false,
    ).toException(cause: error is EmbeddingException ? error.cause : null);

Future<void> _closeAfterFailedLoad(
  EmbeddingPass pass,
  String engine,
  String label,
  Duration slowCloseNotice,
) async {
  final notice = Timer(
    slowCloseNotice,
    () => warnEmbeddingHost(
      'closing the $engine embedding pass for $label after its load failed '
      'has taken ${describeHostDuration(slowCloseNotice)} and is still '
      'running. No new embedder is built until it ends.',
    ),
  );
  try {
    final error = await closePassReportingFailure(pass);
    if (error != null) {
      warnEmbeddingHost(
        'the $engine embedding pass for $label failed to close after its load '
        'failed; its native model may still be resident: $error',
      );
    }
  } finally {
    notice.cancel();
  }
}

final class _Request {
  _Request(this.input, this.taskType);

  final EmbeddingInput input;
  final TaskType taskType;
  final completer = Completer<List<double>>();
}

final class _InlineEmbeddingHost implements EmbeddingHost {
  _InlineEmbeddingHost(
    this._pass,
    this.info,
    this.modalities, {
    required this._engine,
    required this._label,
    required this._slowCloseNotice,
  }) {
    _pump = RequestPump<_Request>(_serve, yieldToEventLoop: yieldToEventLoop);
    _runDone = _pump.run();
  }

  final EmbeddingPass _pass;
  final String _engine;
  final String _label;
  final Duration _slowCloseNotice;
  late final RequestPump<_Request> _pump;
  late final Future<void> _runDone;
  Future<void>? _closeFuture;

  @override
  final EmbeddingPassInfo info;

  @override
  final Set<EmbeddingModality> modalities;

  /// Never completes: the pass runs on the caller's own isolate, so there is
  /// no worker that could exit under the host.
  @override
  final Future<String> unexpectedExit = Completer<String>().future;

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) {
    final request = _Request(input, taskType);
    if (_closeFuture != null ||
        !_pump.file(request, media: isMediaRequest(input))) {
      return Future.error(closedBeforeRun);
    }
    return request.completer.future;
  }

  Future<void> _serve(_Request request) async {
    try {
      request.completer.complete(
        await _pass.embed(request.input, request.taskType),
      );
    } catch (e, st) {
      request.completer.completeError(
        EmbeddingFailure.fromError(
          e,
          engine: _engine,
          causeInMessage: false,
        ).toException(cause: e is EmbeddingException ? e.cause : null),
        st,
      );
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _shutDown();

  Future<void> _shutDown() async {
    for (final request in _pump.requestClose()) {
      request.completer.completeError(closedBeforeRun);
    }
    final notice = Timer(
      _slowCloseNotice,
      () => warnEmbeddingHost(
        'closing the $_engine embedder for $_label has taken '
        '${describeHostDuration(_slowCloseNotice)}: the embedding request in '
        "flight, or the pass's own close(), has not returned. It keeps "
        'waiting rather than abandon the native model.',
      ),
    );
    try {
      // The pass is closed even if the serving loop ended in an error.
      await runTeardown('closing the $_engine embedder for $_label', [
        () => _runDone,
        () async {
          final error = await closePassReportingFailure(_pass);
          if (error != null) {
            warnEmbeddingHost(
              'the $_engine embedding pass for $_label failed to close; its '
              'native model may still be resident: $error',
            );
          }
        },
      ]);
    } finally {
      notice.cancel();
    }
  }
}
