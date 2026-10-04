// The names this package carried as flutter_gemma. Each is an alias, so code
// written against flutter_gemma compiles unchanged apart from the import, and
// the analyzer points at the new name.

import '../flutter_edge_ai_interface.dart';
import 'api/flutter_edge_ai.dart';
import 'utils/edge_ai_log.dart';

@Deprecated(
  'Use FlutterEdgeAi: flutter_gemma was renamed to flutter_edge_ai '
  '(dart fix --apply migrates). Removed in flutter_edge_ai 2.0.0.',
)
typedef FlutterGemma = FlutterEdgeAi;

@Deprecated(
  'Use FlutterEdgeAiPlugin: flutter_gemma was renamed to flutter_edge_ai '
  '(dart fix --apply migrates). Removed in flutter_edge_ai 2.0.0.',
)
typedef FlutterGemmaPlugin = FlutterEdgeAiPlugin;

@Deprecated(
  'Use EdgeAiLogLevel: flutter_gemma was renamed to flutter_edge_ai '
  '(dart fix --apply migrates). Removed in flutter_edge_ai 2.0.0.',
)
typedef GemmaLogLevel = EdgeAiLogLevel;
