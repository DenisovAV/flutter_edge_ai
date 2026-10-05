// [BuiltInAi] no longer owns a platform channel — it forwards to
// flutter_local_ai, which owns the pigeon and Prompt API hosts. What is still
// this package's to guarantee is the SHAPE of the facade apps already import:
// the seven-value enum they switch on, the exception they catch, and the two
// bounds that stop `ensureReady`/`availability` from hanging.
//
// Both bounds are regressions from a Firebase Test Lab run that stalled for
// nine minutes in setUpAll; neither is expressible with the published fake
// alone, so they use the doubles in `adapter_test_support.dart`.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart';
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show
        LocalAi,
        LocalAiAvailability,
        LocalAiUnavailableException,
        debugLocalAiHost;
import 'package:flutter_local_ai/testing.dart' show FakeLocalAiHost;
import 'package:flutter_test/flutter_test.dart';

import 'adapter_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLocalAiHost host;

  /// Swaps in [fake] for the rest of the test, so a suite can start from the
  /// plain fake and upgrade to a double only where it needs one. Every host
  /// installed is disposed, including one that was replaced mid-test.
  void install(FakeLocalAiHost fake) {
    host = fake;
    debugLocalAiHost = fake;
    addTearDown(fake.dispose);
  }

  setUp(() => install(FakeLocalAiHost()));

  tearDown(() => debugLocalAiHost = null);

  group('source compatibility', () {
    // An app's exhaustive `switch` over BuiltInAiAvailability must still
    // compile after the type became an alias of LocalAiAvailability, which
    // needs the same seven values in the same order.
    test('BuiltInAiAvailability keeps its seven values in order', () {
      expect(BuiltInAiAvailability.values.map((v) => v.name).toList(), [
        'available',
        'downloadable',
        'downloading',
        'unavailableDeviceUnsupported',
        'unavailableOsTooOld',
        'unavailableDisabled',
        'unavailableOther',
      ]);
    });

    test('the availability types are the flutter_local_ai ones', () {
      expect(BuiltInAiAvailability.available, isA<LocalAiAvailability>());
      expect(
        BuiltInAiUnavailableException(
          BuiltInAiAvailability.unavailableOther,
          'why',
        ),
        isA<LocalAiUnavailableException>(),
      );
    });

    test('debugProbeTimeout is the flutter_local_ai probe bound', () {
      final original = BuiltInAi.debugProbeTimeout;
      addTearDown(() => BuiltInAi.debugProbeTimeout = original);

      BuiltInAi.debugProbeTimeout = const Duration(milliseconds: 5);

      expect(BuiltInAi.debugProbeTimeout, const Duration(milliseconds: 5));
      expect(LocalAi.debugProbeTimeout, const Duration(milliseconds: 5));
    });
  });

  group('availability() reports every host value', () {
    for (final status in BuiltInAiAvailability.values) {
      test('$status', () async {
        host.availability = status;
        expect(await BuiltInAi.availability(), status);
      });
    }
  });

  test(
    'ensureReady completes immediately when available (no download)',
    () async {
      await BuiltInAi.ensureReady();

      expect(host.calls, isNot(contains('downloadFeature')));
    },
  );

  test('ensureReady throws BuiltInAiUnavailableException on disabled without '
      'downloading', () async {
    host.availability = BuiltInAiAvailability.unavailableDisabled;

    await expectLater(
      BuiltInAi.ensureReady(),
      throwsA(
        isA<BuiltInAiUnavailableException>().having(
          (e) => e.status,
          'status',
          BuiltInAiAvailability.unavailableDisabled,
        ),
      ),
    );
    expect(host.calls, isNot(contains('downloadFeature')));
  });

  test('ensureReady downloads then resolves when availability flips to '
      'available', () async {
    install(
      ScriptedAvailabilityHost(const [
        BuiltInAiAvailability.downloadable,
        BuiltInAiAvailability.available,
      ]),
    );

    await BuiltInAi.ensureReady();

    expect(host.calls, contains('downloadFeature'));
    expect(
      host.calls.where((call) => call == 'checkAvailability').length,
      greaterThanOrEqualTo(2),
    );
  });

  // Regression for the Firebase Test Lab hang: on a fresh device the AICore
  // download queue may never grant a slot, so the native downloadFeature()
  // Flow emits nothing and its reply never arrives, while availability stays
  // `downloadable`. ensureReady must be bounded by its own timeout and throw
  // TimeoutException — NOT block forever on the download call.
  test('ensureReady times out (does not hang) when download never completes '
      'and availability never flips', () async {
    install(
      HangingHost(
        hangDownload: true,
        availability: BuiltInAiAvailability.downloadable,
      ),
    );

    await expectLater(
      BuiltInAi.ensureReady(timeout: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
  });

  // Regression for the Firebase Test Lab hang (root cause): on a device whose
  // OS AI stack is not initialized (AICore with no Phenotype metadata), the
  // native status call never returns. availability() must be bounded and
  // resolve to unavailableOther so a caller that gates on it can skip cleanly.
  test('availability() resolves to unavailableOther when the host probe never '
      'returns (does not hang)', () async {
    install(HangingHost(hangProbe: true));
    final original = BuiltInAi.debugProbeTimeout;
    BuiltInAi.debugProbeTimeout = const Duration(milliseconds: 200);
    addTearDown(() => BuiltInAi.debugProbeTimeout = original);

    final result = await BuiltInAi.availability().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('availability() hung past its probe bound'),
    );

    expect(result, BuiltInAiAvailability.unavailableOther);
  });

  // Linux has no OS model and flutter_local_ai registers no plugin there, so
  // its own probe would say `unavailableOther`. The facade keeps 0.2.2's
  // answer; the fake host is never asked, which is what the empty call log
  // shows.
  group('on Linux', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('availability() is unavailableDeviceUnsupported', () async {
      expect(
        await BuiltInAi.availability(),
        BuiltInAiAvailability.unavailableDeviceUnsupported,
      );
      expect(host.calls, isEmpty);
    });

    test('ensureReady() throws BuiltInAiUnavailableException', () async {
      await expectLater(
        BuiltInAi.ensureReady(),
        throwsA(
          isA<BuiltInAiUnavailableException>().having(
            (e) => e.status,
            'status',
            BuiltInAiAvailability.unavailableDeviceUnsupported,
          ),
        ),
      );
      expect(host.calls, isEmpty);
    });
  });
}
