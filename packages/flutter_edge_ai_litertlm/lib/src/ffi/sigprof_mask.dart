import 'dart:ffi';

import 'package:ffi/ffi.dart';

// glibc's sigset_t is 1024 bits; SIG_BLOCK/SIG_SETMASK and SIGPROF have these
// values on every Linux ABI the package ships (asm-generic and x86_64 alike).
const _sigsetWords = 16;
const _sigBlock = 0;
const _sigSetmask = 2;
const _sigprof = 27;

typedef _PthreadSigmaskNative =
    Int32 Function(Int32 how, Pointer<Uint64> set, Pointer<Uint64> oldset);
typedef _PthreadSigmask =
    int Function(int how, Pointer<Uint64> set, Pointer<Uint64> oldset);

/// Runs [body] with SIGPROF blocked on the calling thread, then restores the
/// thread's previous mask. Linux only.
///
/// A debug or profile Dart VM samples every isolate thread with SIGPROF about
/// once a millisecond, inside FFI calls too. Qualcomm's QNN HTP backend does
/// not survive that on Linux: `litert_lm_engine_create` for npu fails with
/// "Failed to initialize QNN backend" while the VM profiler runs. Measured on
/// a QCS8275 board: a plain `dart` program creates the engine, the same
/// program under `--profiler` gets null, and with SIGPROF blocked around the
/// call it creates it again. Release builds run no profiler.
///
/// The VM signals a thread with pthread_kill and does not wait, so a blocked
/// SIGPROF stays pending and is taken when the mask is restored. Threads the
/// native code starts meanwhile inherit the mask; the VM never samples them.
T withSigprofBlocked<T>(T Function() body) {
  final sigmask = DynamicLibrary.process()
      .lookupFunction<_PthreadSigmaskNative, _PthreadSigmask>(
        'pthread_sigmask',
      );
  final block = calloc<Uint64>(_sigsetWords);
  final saved = calloc<Uint64>(_sigsetWords);
  try {
    block[0] = 1 << (_sigprof - 1);
    final rc = sigmask(_sigBlock, block, saved);
    if (rc != 0) {
      throw StateError('pthread_sigmask(SIG_BLOCK, SIGPROF) returned $rc');
    }
    try {
      return body();
    } finally {
      sigmask(_sigSetmask, saved, nullptr);
    }
  } finally {
    calloc.free(block);
    calloc.free(saved);
  }
}
