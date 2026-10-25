// `LiteRtLmEngine(thinkingTokenBudget:)`: the check both arms run, and the
// web arm's one-time notice that the budget does not apply there. Web-safe.

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

/// The largest budget LiteRT-LM can take: its setter's parameter is a C
/// `int`, 32 bits on every platform the plugin runs on.
const maxThinkingTokenBudget = 0x7fffffff;

/// Throws [ArgumentError] for a [budget] LiteRT-LM cannot take: below 1, or
/// above [maxThinkingTokenBudget], which the C `int` would wrap (`1 << 32`
/// would arrive as 0, which is no budget). Null, no budget, passes.
void checkThinkingTokenBudget(int? budget) {
  if (budget == null) return;
  if (budget < 1 || budget > maxThinkingTokenBudget) {
    throw ArgumentError.value(
      budget,
      'thinkingTokenBudget',
      'must be between 1 and $maxThinkingTokenBudget; null sets no budget',
    );
  }
}

/// Said once per isolate: the budget is set at registration, so every load
/// would repeat the same line.
bool _noticed = false;

/// Says, once per isolate and in debug builds only (`edgeAiLog`), that the
/// web engine ignores `thinkingTokenBudget`: `@litert-lm/core` 0.18.0 has no
/// such setting. The web engine accepts it so that one registration compiles
/// on every platform. Nothing here changes what runs.
void noticeThinkingTokenBudgetIgnoredOnWeb() {
  if (_noticed) return;
  // Spend the one shot only on a line that can appear: an app that starts
  // silent and raises the level later still gets it.
  if (!kDebugMode || edgeAiLogLevel == EdgeAiLogLevel.none) return;
  _noticed = true;
  edgeAiLog(
    'ℹ️  LiteRtLmEngine(thinkingTokenBudget:) is ignored on the web: '
    '@litert-lm/core has no thinking budget. A web turn with thinking on can '
    'still think until maxOutputTokens.',
  );
}

/// Lets a test start from a known state.
@visibleForTesting
void resetThinkingTokenBudgetNotice() => _noticed = false;
