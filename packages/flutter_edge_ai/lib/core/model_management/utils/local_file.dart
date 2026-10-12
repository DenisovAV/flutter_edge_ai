/// Files on disk for the install rule and the restores, without `dart:io` in
/// the web build: see `local_file_io.dart`.
library;

export 'local_file_io.dart' if (dart.library.js_interop) 'local_file_web.dart';
