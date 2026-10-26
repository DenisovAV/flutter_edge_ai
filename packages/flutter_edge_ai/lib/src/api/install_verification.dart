import 'package:flutter_edge_ai/src/model_management/model_specs.dart';

/// A check an installation builder runs on the installed spec right before
/// it makes the spec active, keyed by the builder. A throw leaves the files
/// installed and the spec not active. (A TTS install has already taken the
/// active voice of the same type out of service when it replaced files; it
/// stays out of service.)
///
/// Internal: `FlutterEdgeAi.installFromCatalog` sets it to compare each file
/// with the catalog's size, so a file of the wrong size never becomes the
/// active model.
final verifyBeforeActivation = Expando<Future<void> Function(ModelSpec spec)>(
  'verifyBeforeActivation',
);

/// Each file's own download progress, 0 to 100 by the file's name, keyed by
/// the builder; a file found already installed reports 100. Set by
/// `FlutterEdgeAi.installFromCatalog` on a TTS install, whose public
/// `withProgress` counts finished files, so the catalog can weight its one
/// progress by file size as it does for the other kinds.
final fileProgressFor = Expando<void Function(String filename, int percent)>(
  'fileProgressFor',
);
