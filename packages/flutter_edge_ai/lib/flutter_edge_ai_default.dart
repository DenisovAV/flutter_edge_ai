import 'flutter_edge_ai_interface.dart';
import 'mobile/flutter_edge_ai_mobile.dart';

/// Default [FlutterEdgeAiPlugin] for platforms with `dart:io` (mobile + desktop).
///
/// Selected via conditional import from `flutter_edge_ai_interface.dart`. Keeping
/// the `FlutterEdgeAiMobile` reference behind this file is what keeps `dart:io`
/// off the web/wasm import graph (see [flutter_edge_ai_default_web.dart]).
FlutterEdgeAiPlugin defaultFlutterEdgeAiInstance() => FlutterEdgeAiMobile();
