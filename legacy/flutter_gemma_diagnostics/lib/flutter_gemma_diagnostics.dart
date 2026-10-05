/// Opt-in memory diagnostics for flutter_gemma apps, read from the OS on
/// Android and iOS.
library;

export 'src/diagnostics_stub.dart'
    if (dart.library.ffi) 'src/diagnostics_io.dart';
export 'src/memory_read_exception.dart';
export 'src/memory_snapshot.dart';
