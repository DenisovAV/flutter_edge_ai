import 'interface.dart';
import 'mobile/flutter_edge_ai_mobile.dart';

/// Default [FlutterEdgeAiPlugin] for platforms with `dart:io` (mobile + desktop).
///
/// Selected via conditional import from `interface.dart`. Keeping
/// the `FlutterEdgeAiMobile` reference behind this file is what keeps `dart:io`
/// off the web/wasm import graph (see `default_web.dart`).
FlutterEdgeAiPlugin defaultFlutterEdgeAiInstance() => FlutterEdgeAiMobile();
