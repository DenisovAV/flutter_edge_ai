import 'dart:async';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart'
    show MemoryReadException;

/// What a [PeakSampler] saw while it ran.
///
/// [bytes] is the highest value read, or null if nothing was read. [samples]
/// counts the periodic reads that returned a value, so 0 means the number
/// comes from the boundary readings alone. [failures] counts periodic reads
/// that failed, and [firstFailure] is the first one's message. A read that
/// returned null (no such value here) is neither. [intervalMs] is the
/// sampler's interval, null when it was off. [readMs] is how long the
/// successful periodic reads took, null when there were none: on a device
/// where one read costs ~150 ms this is the bias the run carries.
typedef PeakReading = ({
  int? bytes,
  int samples,
  int failures,
  String? firstFailure,
  int? intervalMs,
  ({double mean, double max})? readMs,
});

/// Tracks the highest value a reader returns while it runs.
///
/// This is a sampled peak, not a high-water mark: a spike shorter than
/// [interval] can fall between two reads and be missed. The reader runs on the
/// calling isolate, so a read that is still in flight when the next tick
/// arrives makes that tick skip instead of queueing behind it. An [interval]
/// of [Duration.zero] switches the sampler off: [start] does nothing and the
/// result comes from [observe] and `stop(last:)` alone.
///
/// A window covers only what runs between [start] and [stop]. Work done
/// between two windows is in neither, for example creating a chat for a vision
/// or audio prompt, where the encoder's kernels compile after the load window
/// has closed and before the prompt window opens.
///
/// A [MemoryReadException] from the reader counts as a failed sample. Anything
/// else is a bug in the reader and is allowed to surface, in [stop] or as an
/// uncaught async error.
class PeakSampler {
  PeakSampler({required this.read, required this.interval});

  /// Returns one reading, or null when the value does not exist here.
  final Future<int?> Function() read;
  final Duration interval;

  int? _peak;
  int _samples = 0;
  int _failures = 0;
  String? _firstFailure;
  int _readMicros = 0;
  int _maxReadMicros = 0;
  Timer? _timer;
  bool _reading = false;
  Future<void>? _pending;

  bool get _enabled => interval > Duration.zero;

  /// Counts [bytes] toward the peak without counting it as a periodic sample.
  /// Used for the readings taken at the boundaries of the measured window.
  void observe(int? bytes) {
    if (bytes != null && (_peak == null || bytes > _peak!)) _peak = bytes;
  }

  /// Starts reading every [interval]. The first read happens one interval in.
  void start() {
    assert(_timer == null, 'start() called twice');
    if (!_enabled) return;
    _timer = Timer.periodic(interval, (_) {
      if (_reading) return;
      _reading = true;
      _pending = _tick();
    });
  }

  Future<void> _tick() async {
    final watch = Stopwatch()..start();
    try {
      final value = await read();
      watch.stop();
      if (value != null) {
        observe(value);
        _samples++;
        _readMicros += watch.elapsedMicroseconds;
        if (watch.elapsedMicroseconds > _maxReadMicros) {
          _maxReadMicros = watch.elapsedMicroseconds;
        }
      }
    } on MemoryReadException catch (e) {
      _failures++;
      _firstFailure ??= '$e';
    } finally {
      _reading = false;
    }
  }

  /// Stops sampling, waits for a read already in flight, and returns what was
  /// seen. [last] is a boundary reading to count toward the peak.
  Future<PeakReading> stop({int? last}) async {
    _timer?.cancel();
    _timer = null;
    await _pending;
    observe(last);
    return (
      bytes: _peak,
      samples: _samples,
      failures: _failures,
      firstFailure: _firstFailure,
      intervalMs: _enabled ? interval.inMilliseconds : null,
      readMs: _samples == 0
          ? null
          : (mean: _readMicros / _samples / 1000, max: _maxReadMicros / 1000),
    );
  }

  /// Stops sampling and waits for a read already in flight, discarding the
  /// result and any error from that read. For cleanup on an error path, where
  /// a failure here must not replace the error being propagated.
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
    try {
      await _pending;
    } catch (_) {}
  }
}
