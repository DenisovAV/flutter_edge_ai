import 'dart:async';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart'
    show MemoryReadException;

/// What a [PeakSampler] saw while it ran.
///
/// [bytes] is the highest value read, or null if nothing was read. [samples]
/// counts the periodic reads that succeeded, so 0 means the number comes from
/// the boundary readings alone. [failures] counts periodic reads that failed,
/// and [firstFailure] is the first one's message.
typedef PeakReading = ({
  int? bytes,
  int samples,
  int failures,
  String? firstFailure,
});

/// Tracks the highest value a reader returns while it runs.
///
/// This is a sampled peak, not a high-water mark: a spike shorter than
/// [interval] can fall between two reads and be missed. The reader runs on the
/// calling isolate, so a read that is still in flight when the next tick
/// arrives makes that tick skip instead of queueing behind it.
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
  Timer? _timer;
  bool _reading = false;
  Future<void>? _pending;

  /// Counts [bytes] toward the peak without counting it as a periodic sample.
  /// Used for the readings taken at the boundaries of the measured window.
  void observe(int? bytes) {
    if (bytes != null && (_peak == null || bytes > _peak!)) _peak = bytes;
  }

  /// Starts reading every [interval]. The first read happens one interval in.
  void start() {
    assert(_timer == null, 'start() called twice');
    _timer = Timer.periodic(interval, (_) {
      if (_reading) return;
      _reading = true;
      _pending = _tick();
    });
  }

  Future<void> _tick() async {
    try {
      observe(await read());
      _samples++;
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
    );
  }
}
