/// Opt-in memory diagnostics for flutter_edge_ai apps, read from the OS on
/// Android, iOS, macOS, Linux and Windows.
library;

export 'src/diagnostics_stub.dart'
    if (dart.library.ffi) 'src/diagnostics_io.dart';
export 'src/gpu_memory_reading.dart';
export 'src/memory_read_exception.dart';
export 'src/memory_snapshot.dart';
