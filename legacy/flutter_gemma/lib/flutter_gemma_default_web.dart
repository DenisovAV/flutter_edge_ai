import 'flutter_gemma_interface.dart';

/// Web default for [FlutterGemmaPlugin] — never actually used at runtime.
///
/// On web, `FlutterGemmaWeb` registers itself as `FlutterGemmaPlugin.instance`
/// during plugin registration, so this default is overwritten before any call.
/// It exists only so the web/wasm compile graph doesn't pull in
/// `FlutterGemmaMobile` (and its `dart:io`).
FlutterGemmaPlugin defaultFlutterGemmaInstance() => throw UnsupportedError(
  'No default FlutterGemmaPlugin on web — FlutterGemmaWeb must register '
  'itself as the platform instance during plugin registration.',
);
