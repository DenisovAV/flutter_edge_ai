import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';

/// The sha256 of the file at [path], hex, read as a stream on a worker
/// isolate: a model of several GB takes seconds to minutes to hash, which
/// would otherwise be spent on the caller's (usually the UI) isolate.
///
/// A cancel of [cancelToken] stops the worker and throws
/// [DownloadCancelledException].
Future<String> fileSha256(String path, {CancelToken? cancelToken}) async {
  cancelToken?.throwIfCancelled();
  final answer = ReceivePort();
  final isolate = await Isolate.spawn(
    _hashInto,
    (answer.sendPort, path),
    onError: answer.sendPort,
    onExit: answer.sendPort,
    errorsAreFatal: true,
  );
  final done = Completer<String>();
  final subscription = answer.listen((message) {
    if (done.isCompleted) return;
    switch (message) {
      case String hex:
        done.complete(hex);
      case [final Object error, final Object? stack]:
        done.completeError(
          FileSystemException('$error', path),
          StackTrace.fromString('$stack'),
        );
      default:
        done.completeError(
          FileSystemException('the hashing isolate stopped', path),
        );
    }
  });
  unawaited(
    cancelToken?.whenCancelled.then((_) {
      if (done.isCompleted) return;
      isolate.kill(priority: Isolate.immediate);
      try {
        cancelToken.throwIfCancelled();
      } catch (e, stack) {
        done.completeError(e, stack);
      }
    }),
  );
  try {
    return await done.future;
  } finally {
    await subscription.cancel();
    answer.close();
  }
}

Future<void> _hashInto((SendPort, String) request) async {
  final (reply, path) = request;
  reply.send('${await sha256.bind(File(path).openRead()).first}');
}
