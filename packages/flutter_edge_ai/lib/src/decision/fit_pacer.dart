// How a decider fit shares its thread. Natively the fit runs on an isolate of
// its own and never pauses; on web it runs on the page's one thread and gives
// the event loop a turn every few milliseconds (fit_runner_web.dart).

/// Asked between units of a fit's work — a row, a fold, a history entry —
/// whether to pause there.
abstract interface class FitPacer {
  /// Null to go on at once; otherwise a future the fit awaits before going
  /// on. A future that fails (a cancel) ends the fit with its error.
  Future<void>? pause();
}

/// [pacer]'s pause, or null without a pacer. Call sites write
/// `if (pauseFor(pacer) case final turn?) await turn;`, so an unpaced fit
/// never awaits.
Future<void>? pauseFor(FitPacer? pacer) => pacer?.pause();
