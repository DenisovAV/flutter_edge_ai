import 'flutter_gemma_interface.dart';
import 'mobile/flutter_gemma_mobile.dart';

/// Default [FlutterGemmaPlugin] for platforms with `dart:io` (mobile + desktop).
///
/// Selected via conditional import from `flutter_gemma_interface.dart`. Keeping
/// the `FlutterGemmaMobile` reference behind this file is what keeps `dart:io`
/// off the web/wasm import graph (see [flutter_gemma_default_web.dart]).
FlutterGemmaPlugin defaultFlutterGemmaInstance() => FlutterGemmaMobile();
