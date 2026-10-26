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
