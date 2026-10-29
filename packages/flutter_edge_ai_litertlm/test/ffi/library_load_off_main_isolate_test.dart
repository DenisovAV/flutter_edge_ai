import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The process's first load of the libraries ran on the calling isolate, 13 ms
/// on an S25 Ultra on its own, before `initialize` even spawned its
/// engine-create isolate. It now goes through [offMainIsolate] (`Isolate.run`
/// in production). These tests replace that seam, so what they can see is the
/// dispatch itself. What they cannot see is the timing: that needs a device.
void main() {
  late Future<void> Function(void Function()) originalRunner;

  setUp(() => originalRunner = offMainIsolate);

  tearDown(() => offMainIsolate = originalRunner);

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
}
