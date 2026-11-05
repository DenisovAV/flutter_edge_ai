// Rules the #779 review asked to hold with tests: a long native text is read
// whole, a context_full send is kept for L3's rewind, and a release build's
// skipped scoring self-check does not read as passed.
// The decider SPI is @experimental.
// ignore_for_file: experimental_member_use

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart'
    show NativeTurnEnd;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a generated text or reply past 64 KiB is read whole; an error message '
      'is bounded', () {
    final long = List.filled(200 * 1024, 'é').join(); // 400 KiB of UTF-8
    final native = long.toNativeUtf8();
    addTearDown(() => malloc.free(native));
    expect(decodeNativeString(native.cast()), long);
    expect(
      decodeNativeString(native.cast(), maxBytes: 64 * 1024).length,
      lessThanOrEqualTo(64 * 1024),
    );
  });

  test('the last send is kept after a cancel and after context_full, and '
      'dropped after any other end', () {
    for (final how in NativeTurnEnd.values) {
      for (final end in [...NativeLastTurnEnd.values, null]) {
        expect(
          keepLastSendAfter(how, end),
          how == NativeTurnEnd.cancelled ||
              end == NativeLastTurnEnd.contextFull,
          reason: '$how $end',
        );
      }
    }
  });

  test('a synchronous stream-start failure is a refusal even when native '
      '0.19 records failed', () {
    expect(
      streamStartFailureTurnEnd(NativeLastTurnEnd.failed),
      NativeLastTurnEnd.refused,
    );
  });

  test('a synchronous context_full keeps its recovery classification', () {
    expect(
      streamStartFailureTurnEnd(NativeLastTurnEnd.contextFull),
      NativeLastTurnEnd.contextFull,
    );
  });

  test(
    'a turn that failed with RESOURCE_EXHAUSTED (native 37d1ec59: a failed '
    'allocation, not a full window) is handled as failed, never as '
    'context_full: it keeps no last send and a rewind reporting it rebuilds',
    () {
      for (final how in NativeTurnEnd.values) {
        expect(
          keepLastSendAfter(how, NativeLastTurnEnd.failed),
          how == NativeTurnEnd.cancelled,
        );
      }
      expect(
        () => stoppedTurnRewindOutcome(13, NativeLastTurnEnd.failed.index, 'x'),
        throwsA(isA<StoppedTurnRewindException>()),
      );
    },
  );

  test('a release build skips the scoring self-check, and the model does not '
      'report it as passed', () async {
    liteRtLmScoringReleaseMode = true;
    addTearDown(() => liteRtLmScoringReleaseMode = false);
    final model = FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      onClose: () {},
    );
    final scorer = await model.openOptionScorer();
    // No engine is loaded: a self-check that ran would fail on its first
    // native call. Skipped, it touches nothing.
    await scorer.prepare(['yes', 'no']);
    expect(model.scoringChecked, isFalse);
    await scorer.close();
  });
}
