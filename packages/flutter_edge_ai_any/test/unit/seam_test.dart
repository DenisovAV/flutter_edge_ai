// The fake runtime sends every job through a port, as the FFI runtime
// sends it to a worker isolate: a job that captures what cannot cross an
// isolate fails in the unit tests, not first on a device.
import 'dart:isolate';

import 'package:flutter_edge_ai_any/src/native/any_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_native.dart';

void main() {
  test('a job capturing a ReceivePort is refused', () async {
    final rt = await FakeNetwork().native().start();
    final port = ReceivePort();
    addTearDown(port.close);
    await expectLater(
      rt.index((h) => port.hashCode),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a job is a copy: what it mutates stays on its side', () async {
    final rt = await FakeNetwork().native().start();
    final captured = <int>[];
    await rt.index((h) => captured.add(1));
    expect(captured, isEmpty);
  });

  test('awaitOp waits in slices and stops at the deadline', () async {
    final net = FakeNetwork();
    final rt = await net.native().start() as FakeRuntime;
    final sdk = rt.sdkImpl;
    sdk.openAccount({'dataDir': '/d', 'ownerToken': 't', 'mnemonic': 'm'});
    final space = sdk.spaceCreate('s')['id']! as String;
    sdk.device!.loading.add(space);
    final op = sdk.spaceResolveStart(space);
    final sw = Stopwatch()..start();
    final r = await awaitOp(
      sdk,
      op,
      deadline: DateTime.now().add(const Duration(milliseconds: 50)),
    );
    expect(r, isNull);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('ownerToken is stable within an isolate', () {
    expect(ownerToken(), ownerToken());
    expect(ownerToken(), hasLength(32));
  });
}
