@TestOn('linux')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/sigprof_mask.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _SigmaskNative =
    Int32 Function(Int32, Pointer<Uint64>, Pointer<Uint64>);
typedef _Sigmask = int Function(int, Pointer<Uint64>, Pointer<Uint64>);

final _sigmask = DynamicLibrary.process()
    .lookupFunction<_SigmaskNative, _Sigmask>('pthread_sigmask');
const _sigprofBit = 1 << (27 - 1);

/// Whether SIGPROF is in this thread's mask right now.
bool _sigprofBlocked() {
  final current = calloc<Uint64>(16);
  try {
    // SIG_BLOCK with a null set only reads the mask.
    expect(_sigmask(0, nullptr, current), 0);
    return current[0] & _sigprofBit != 0;
  } finally {
    calloc.free(current);
  }
}

void _setSigprof({required bool blocked}) {
  final set = calloc<Uint64>(16)..[0] = _sigprofBit;
  try {
    expect(_sigmask(blocked ? 0 : 1, set, nullptr), 0);
  } finally {
    calloc.free(set);
  }
}

void main() {
  test('blocks SIGPROF inside and unblocks it after', () {
    _setSigprof(blocked: false);
    expect(withSigprofBlocked(_sigprofBlocked), isTrue);
    expect(_sigprofBlocked(), isFalse);
  });

  test('restores the previous mask rather than unblocking', () {
    _setSigprof(blocked: true);
    try {
      expect(withSigprofBlocked(_sigprofBlocked), isTrue);
      expect(_sigprofBlocked(), isTrue);
    } finally {
      _setSigprof(blocked: false);
    }
  });

  test('restores the mask when the body throws', () {
    _setSigprof(blocked: false);
    expect(
      () => withSigprofBlocked<void>(() => throw StateError('x')),
      throwsStateError,
    );
    expect(_sigprofBlocked(), isFalse);
  });

  test('returns the body result', () {
    expect(withSigprofBlocked(() => 42), 42);
  });
}
