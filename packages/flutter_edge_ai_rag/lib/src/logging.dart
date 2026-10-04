import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

/// Writes a debug-only diagnostic through Flutter Edge AI's shared logger.
///
/// Provider packages use this forwarding seam instead of importing core
/// implementation files directly. Like the core logger, it is silent in
/// release builds.
void ragLog(String message) => edgeAiLog(message);
