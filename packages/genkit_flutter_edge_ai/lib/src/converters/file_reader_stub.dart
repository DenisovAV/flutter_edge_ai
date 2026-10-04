import 'dart:typed_data';

import 'package:genkit/plugin.dart';

/// Stub implementation for platforms without dart:io (Web).
///
/// File paths and `file://` URIs are not supported on Web.
Future<Uint8List> readFileBytes(String path) async {
  throw GenkitException(
    'File-based media is not supported on this platform: $path',
    status: StatusCodes.UNIMPLEMENTED,
  );
}
