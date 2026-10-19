/// The minimum severity of LiteRT-LM's own native log:
/// `LiteRtLmLogSeverity` of its C API (`litert_lm_set_min_log_level`).
///
/// Passed as `LiteRtLmEngine(nativeLogLevel:)`, read on native platforms
/// only. The level is process-wide: it applies to every LiteRT-LM engine in
/// the process, and the last value set wins.
enum LiteRtLmLogLevel {
  verbose(0),
  debug(1),
  info(2),
  warning(3),
  error(4),
  fatal(5),

  /// Nothing is written.
  silent(1000);

  const LiteRtLmLogLevel(this.nativeValue);

  /// The `LiteRtLmLogSeverity` value.
  final int nativeValue;
}
