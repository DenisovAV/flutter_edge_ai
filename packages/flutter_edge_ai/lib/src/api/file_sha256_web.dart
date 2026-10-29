import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';

/// The web keeps no local file to hash: the browser stores what it fetched.
Future<String> fileSha256(String path, {CancelToken? cancelToken}) =>
    throw UnsupportedError('no local files to hash on the web');
