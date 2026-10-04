import 'flutter_edge_ai_interface.dart';

/// Web default for [FlutterEdgeAiPlugin] — never actually used at runtime.
///
/// On web, `FlutterEdgeAiWeb` registers itself as `FlutterEdgeAiPlugin.instance`
/// during plugin registration, so this default is overwritten before any call.
/// It exists only so the web/wasm compile graph doesn't pull in
/// `FlutterEdgeAiMobile` (and its `dart:io`).
FlutterEdgeAiPlugin defaultFlutterEdgeAiInstance() => throw UnsupportedError(
  'No default FlutterEdgeAiPlugin on web — FlutterEdgeAiWeb must register '
  'itself as the platform instance during plugin registration.',
);
