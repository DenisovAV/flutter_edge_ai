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
/// [DownloadCancelledException]. A file that cannot be read throws the
/// [FileSystemException] the worker met, with its OS error.
Future<String> fileSha256(String path, {CancelToken? cancelToken}) async {
  cancelToken?.throwIfCancelled();
  final answer = ReceivePort();
  try {
    final isolate = await Isolate.spawn(_hashInto, (
      answer.sendPort,
      path,
    ), onExit: answer.sendPort);
    final done = Completer<String>();
    final subscription = answer.listen((message) {
      if (done.isCompleted) return;
      switch (message) {
        case String hex:
          done.complete(hex);
        case (String error, String? osMessage, int? osCode):
          done.completeError(
            FileSystemException(
              error,
              path,
              osMessage == null ? null : OSError(osMessage, osCode ?? 0),
            ),
          );
        default:
          done.completeError(
            FileSystemException('the hashing isolate stopped', path),
          );
      }
    });
    if (cancelToken != null) {
      unawaited(
        Future.any([cancelToken.whenCancelled, done.future]).then((_) {
          if (done.isCompleted) return;
          isolate.kill(priority: Isolate.immediate);
          try {
            cancelToken.throwIfCancelled();
          } catch (e, stack) {
            done.completeError(e, stack);
          }
        }, onError: (_) {}),
      );
    }
    try {
      return await done.future;
    } finally {
      await subscription.cancel();
    }
  } finally {
    answer.close();
  }
}

Future<void> _hashInto((SendPort, String) request) async {
  final (reply, path) = request;
  try {
    reply.send('${await sha256.bind(File(path).openRead()).first}');
  } on FileSystemException catch (e) {
    reply.send((e.message, e.osError?.message, e.osError?.errorCode));
  } catch (e) {
    reply.send(('$e', null, null));
  }
}
