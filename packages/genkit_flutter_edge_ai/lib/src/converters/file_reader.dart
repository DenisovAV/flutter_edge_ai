/// Platform-adaptive file reader.
///
/// Uses conditional export to provide a real implementation on native
/// platforms (dart:io) and an unsupported stub on Web.
library;

export 'file_reader_stub.dart'
    if (dart.library.io) 'file_reader_io.dart';
