/// Shared fixtures and host doubles for the adapter suites.
///
/// The package no longer owns a platform channel, so these suites drive
/// flutter_local_ai's published [FakeLocalAiHost] instead of mocking pigeon by
/// name. Three behaviours these tests need are outside that fake's contract,
/// so they are added here as thin subclasses rather than as a second fake:
/// flutter_local_ai owns the host interface, and a divergent copy would stop
/// tracking it.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart'
    show
        InferenceModelSpec,
        ModelFileType,
        ModelSource,
        ModelType,
        RuntimeConfig;
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show LocalAiAvailability, LocalAiGenerationOverrides;
import 'package:flutter_local_ai/testing.dart' show FakeLocalAiHost;
import 'package:flutter_test/flutter_test.dart' show pumpEventQueue;

/// The spec the engine is meant to claim. [fileType] is a parameter so a
/// suite can hand the engine a spec that belongs to another engine.
InferenceModelSpec builtInSpec({
  ModelFileType fileType = ModelFileType.builtIn,
}) => InferenceModelSpec(
  name: 'gemini-nano',
  modelSource: ModelSource.bundled('gemini-nano'),
  modelType: ModelType.general,
  fileType: fileType,
);

/// A plain text-only runtime config. `modelPath` is empty because a built-in
/// model has no file — the OS owns the weights.
const builtInConfig = RuntimeConfig(maxTokens: 4096, modelPath: '');

/// A host whose availability follows a script instead of one fixed value.
///
/// [FakeLocalAiHost.availability] is a single mutable field, so it cannot
/// express the `downloadable` → `available` transition that
/// `BuiltInAi.ensureReady` is built around. Each probe takes the next entry;
/// the last entry then repeats for every further probe.
class ScriptedAvailabilityHost extends FakeLocalAiHost {
  ScriptedAvailabilityHost(List<LocalAiAvailability> script)
    : _script = List.of(script),
      super(availability: script.first);

  final List<LocalAiAvailability> _script;

  @override
  Future<LocalAiAvailability> checkAvailability() {
    availability = _script.length > 1 ? _script.removeAt(0) : _script.first;
    // Through super so the probe is still recorded in `calls`.
    return super.checkAvailability();
  }
}

/// A host whose probe and/or feature download never answers.
///
/// [FakeLocalAiHost] completes every call, so it cannot reproduce the two
/// Firebase Test Lab hangs the availability suite regresses: an OS status
/// call that never returns, and a feature download the system queue never
/// grants a slot to.
class HangingHost extends FakeLocalAiHost {
  HangingHost({
    this.hangProbe = false,
    this.hangDownload = false,
    super.availability,
  });

  /// `checkAvailability` never completes.
  final bool hangProbe;

  /// `downloadFeature` never completes.
  final bool hangDownload;

  @override
  Future<LocalAiAvailability> checkAvailability() {
    if (!hangProbe) return super.checkAvailability();
    calls.add('checkAvailability');
    return Completer<LocalAiAvailability>().future;
  }

  @override
  Future<void> downloadFeature() {
    if (!hangDownload) return super.downloadFeature();
    calls.add('downloadFeature');
    return Completer<void>().future;
  }
}

/// A host that records turn-building calls in order.
///
/// [FakeLocalAiHost] records `addQueryChunk`/`addImage` into the session's
/// transcript and image list — which says *what* arrived but not in which
/// order, and image-before-text is exactly what the native multimodal
/// requests require.
class TurnOrderHost extends FakeLocalAiHost {
  @override
  Future<void> addQueryChunk({required int sessionId, required String text}) {
    calls.add('addQueryChunk');
    return super.addQueryChunk(sessionId: sessionId, text: text);
  }

  @override
  Future<void> addImage({
    required int sessionId,
    required Uint8List imageBytes,
  }) {
    calls.add('addImage');
    return super.addImage(sessionId: sessionId, imageBytes: imageBytes);
  }

  /// Only the turn-building calls, in the order they were made.
  List<String> get turnCalls => [
    for (final call in calls)
      if (call == 'addImage' || call == 'addQueryChunk') call,
  ];
}

/// A host whose structured calls wait until the test answers them.
///
/// [FakeLocalAiHost.generateStructuredResponse] answers at once, so a stop, a
/// cancel or a close can never land while its turn is running. Like the real
/// hosts, a stop here only asks: the call settles later, when the test calls
/// [settleStopped] (Apple fails a cancelled request, Windows fails it as
/// cancelled, Chrome answers '').
class PendingStructuredHost extends FakeLocalAiHost {
  /// The call in flight, completed by the test.
  Completer<String>? pending;

  /// When set, [stopGeneration] throws it (after recording the call).
  Object? stopError;

  /// When set, closing a session fails the call in flight first, as an OS
  /// does with a request on a session it is tearing down.
  bool failCallOnClose = false;

  @override
  Future<void> closeSession(int sessionId) async {
    final call = pending;
    if (failCallOnClose && call != null && !call.isCompleted) {
      call.completeError(StateError('session $sessionId was released'));
      // The failure reaches the adapter before the close returns.
      await pumpEventQueue();
    }
    return super.closeSession(sessionId);
  }

  @override
  Future<String> generateStructuredResponse({
    required int sessionId,
    required String schemaJson,
    LocalAiGenerationOverrides? overrides,
  }) {
    // Recorded (schema included) through the fake, whose answer is dropped.
    unawaited(
      super.generateStructuredResponse(
        sessionId: sessionId,
        schemaJson: schemaJson,
        overrides: overrides,
      ),
    );
    return (pending = Completer<String>()).future;
  }

  @override
  Future<void> stopGeneration(int sessionId) async {
    await super.stopGeneration(sessionId);
    final error = stopError;
    if (error != null) throw error;
  }

  /// Fails the call in flight as a cancelled request, as Apple does once its
  /// task has unwound.
  void settleStopped() =>
      pending!.completeError(StateError('cancelled at the model'));

  /// How many stops reached the host.
  int get stops => calls.where((call) => call == 'stopGeneration').length;
}
