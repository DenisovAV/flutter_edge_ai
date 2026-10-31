import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/macos_load_error.dart'
    show macOSLiteRtLmFramework;
import 'package:flutter_test/flutter_test.dart';

/// The process's first load of the libraries ran on the calling isolate, 13 ms
/// on an S25 Ultra on its own, before `initialize` even spawned its
/// engine-create isolate. It now goes through [offMainIsolate] (`Isolate.run`
/// in production). On a spawned isolate it still held up the calling one:
/// `DynamicLibrary.open` keeps its isolate from a safepoint, so a garbage
/// collection waited for the whole load (171-174 ms on an M3 Max). The warm-up
/// hands each library to the platform's own loader first, a plain FFI call,
/// through [preloadNativeLibrary].
///
/// These tests replace those seams, so what they can see is the dispatch
/// itself. What they cannot see is the timing: that needs a device.
void main() {
  late Future<void> Function(void Function()) originalRunner;
  late Pointer<Void>? Function(String) originalPreload;

  setUp(() {
    originalRunner = offMainIsolate;
    originalPreload = preloadNativeLibrary;
  });

  tearDown(() {
    offMainIsolate = originalRunner;
    preloadNativeLibrary = originalPreload;
  });

  test('initialize loads the libraries on a spawned isolate before the '
      'calling one opens them', () async {
    var warms = 0;
    offMainIsolate = (work) {
      warms++;
      return Future<void>.error(
        UnsupportedError('no native library on the test host'),
      );
    };
    // No bindings: this client has to load the libraries itself.
    final client = LiteRtLmFfiClient();

    Future<void> initialize() => expectLater(
      client.initialize(modelPath: '/no/such/model.litertlm'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          'no native library on the test host',
        ),
      ),
      reason:
          'the spawned load failed, so initialize failed with ITS error; had '
          'the calling isolate gone on to open the libraries itself, the '
          "failure would be the loader's",
    );

    await initialize();
    expect(warms, 1);

    await initialize();
    expect(
      warms,
      2,
      reason: 'a load that threw is not a load: the next initialize retries it',
    );
  });

  test('the warm-up hands a library to the system loader before '
      'DynamicLibrary.open sees it', () async {
    // Run the warm-up here, where the loader seam is replaced; a spawned
    // isolate would start with its own copy.
    offMainIsolate = (work) async => work();
    final preloaded = <String>[];
    preloadNativeLibrary = (path) {
      preloaded.add(path);
      throw _Preloaded(path);
    };
    final client = LiteRtLmFfiClient();

    await expectLater(
      client.initialize(modelPath: '/no/such/model.litertlm'),
      throwsA(isA<_Preloaded>()),
      reason:
          'the test host has no LiteRT-LM, so a DynamicLibrary.open before '
          "the system loader would have failed with the Dart loader's error",
    );
    final libDir = '${File(Platform.resolvedExecutable).parent.path}/lib';
    final expected = switch (Platform.operatingSystem) {
      'macos' => macOSLiteRtLmFramework,
      'linux' => '$libDir/libStreamProxy.so',
      'windows' => 'StreamProxy.dll',
      _ => null,
    };
    if (expected != null) {
      expect(preloaded, [
        expected,
      ], reason: 'the first library the platform code opens, by its own path');
    }
  });

  test('a loader set on the calling isolate is the one the warm-up isolate '
      'uses', () async {
    // The real runner: a spawned isolate starts with its own copy of every
    // top-level variable, so the loader has to be handed over.
    offMainIsolate = Isolate.run;
    preloadNativeLibrary = (path) => throw _Preloaded(path);

    await expectLater(
      LiteRtLmFfiClient().initialize(modelPath: '/no/such/model.litertlm'),
      throwsA(isA<_Preloaded>()),
      reason:
          'with the default loader the warm-up isolate would go on to '
          "DynamicLibrary.open and fail with the Dart loader's error",
    );
  });

  test('a failed system load says why', () {
    if (Platform.isWindows) return;
    expect(
      () => loadWithSystemLoader('/no/such/dir/libLiteRtLm.so'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('/no/such/dir/libLiteRtLm.so'),
            isNot(contains('no reason given')),
          ),
        ),
      ),
      reason: "dlerror's reason, not lost to a dlsym after the dlopen",
    );
  });

  test('the preloaded and the opened library must be one', () {
    final process = DynamicLibrary.process();
    expect(
      () => requireSameLoadedLibrary(null, process, 'X.framework/X'),
      returnsNormally,
      reason: 'no preload, nothing to compare',
    );
    expect(
      () => requireSameLoadedLibrary(process.handle, process, 'X.framework/X'),
      returnsNormally,
    );
    expect(
      () => requireSameLoadedLibrary(
        Pointer.fromAddress(process.handle.address + 8),
        process,
        'X.framework/X',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('X.framework/X is loaded twice'),
        ),
      ),
    );
  });

  test(
    'the system loader is the platform loader, called through plain FFI',
    () {
      final hostLibrary = switch (Platform.operatingSystem) {
        'macos' => '/usr/lib/libSystem.B.dylib',
        'linux' => 'libc.so.6',
        'windows' => 'kernel32.dll',
        _ => null,
      };
      if (hostLibrary == null) return;
      expect(() => loadWithSystemLoader(hostLibrary), returnsNormally);
      expect(
        () => loadWithSystemLoader('/no/such/dir/libLiteRtLm.so'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('/no/such/dir/libLiteRtLm.so'),
          ),
        ),
      );
    },
  );
}

/// Thrown by the test loader, to stop the warm-up at its first library.
class _Preloaded implements Exception {
  const _Preloaded(this.path);

  final String path;
}
