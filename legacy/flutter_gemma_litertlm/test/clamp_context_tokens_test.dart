// Regression test for #318: a maxTokens below the model's baked
// `kv_cache_max_len` (1024 for every supported .litertlm model) underflows the
// native KV-cache resize and DYNAMIC_UPDATE_SLICE crashes at generation.
// `clampLitertlmContextTokens` raises any value below the floor up to it.
//
// Reproduced on Pixel 8a (Gemma 4 E2B, CPU): 100/256/512 crash, 1024/4096 work.
@TestOn('vm')
library;

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma_litertlm/src/ffi/backend_preference.dart';
import 'package:flutter_gemma_litertlm/src/litert_lm_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clampLitertlmContextTokens (#318)', () {
    test('the floor constant is 1024 (the max known kv_cache_max_len)', () {
      expect(kMinLitertlmContextTokens, 1024);
    });

    test('clamps values below the floor up to 1024', () {
      // The user's exact value, plus the verified-crashing thresholds.
      expect(clampLitertlmContextTokens(100), 1024);
      expect(clampLitertlmContextTokens(256), 1024);
      expect(clampLitertlmContextTokens(512), 1024);
      expect(clampLitertlmContextTokens(1), 1024);
      expect(clampLitertlmContextTokens(1023), 1024);
    });

    test('leaves the floor itself untouched', () {
      expect(clampLitertlmContextTokens(1024), 1024);
    });

    test('passes through values above the floor unchanged', () {
      expect(clampLitertlmContextTokens(2048), 2048);
      expect(clampLitertlmContextTokens(4096), 4096);
      expect(clampLitertlmContextTokens(8192), 8192);
    });

    test('handles zero (treated as below the floor)', () {
      expect(clampLitertlmContextTokens(0), 1024);
    });

    test('clamps for every backend that is not NPU', () {
      for (final backend in [
        null,
        PreferredBackend.cpu,
        PreferredBackend.gpu,
      ]) {
        expect(
          clampLitertlmContextTokens(512, preferredBackend: backend),
          1024,
          reason:
              'the #318 floor is a CPU/GPU fact and still applies to $backend',
        );
      }
    });
  });

  // LiteRT-LM#3508: an NPU bundle is compiled for one cache_length, and on
  // Qualcomm the prefill mask inside the compiled graph has to stay at or under
  // ~1 MiB or every chunk after the first is silently dropped. For the 4-head
  // Gemma 3 bundles the largest working cache_length is 896 — below the #318
  // floor — so clamping up to 1024 would hand the engine the one value that
  // breaks them. The caller's number has to survive.
  group('clampLitertlmContextTokens leaves NPU alone (LiteRT-LM#3508)', () {
    test('896 — the measured Gemma 3 Qualcomm value — is passed through', () {
      expect(
        clampLitertlmContextTokens(896, preferredBackend: PreferredBackend.npu),
        896,
      );
    });

    test('every value below the floor survives on NPU', () {
      for (final tokens in [1, 128, 512, 768, 896, 1023]) {
        expect(
          clampLitertlmContextTokens(
            tokens,
            preferredBackend: PreferredBackend.npu,
          ),
          tokens,
        );
      }
    });

    // The trap this pins: `PreferredBackend.npu` does not mean the NPU runs.
    // `ffiBackendFallbackOrder` retries npu -> gpu -> cpu, so an NPU-sized
    // context below the floor must NOT survive into the attempts that follow —
    // those are the CPU/GPU engines the #318 floor exists for. Resolving the
    // clamp once from the REQUESTED backend (rather than per attempt) is
    // exactly the regression, and it is invisible on a device that has an NPU.
    test(
      'a fallback from NPU re-applies the floor to the backends after it',
      () {
        const requested = 896; // the measured Gemma 3 Qualcomm cache_length
        final perAttempt = {
          // npu pinned on: this case is about the floor being skipped for npu
          // and applied to whatever follows it, which needs a three-backend
          // chain regardless of whether the test host ships an NPU dispatch.
          for (final backend in ffiBackendFallbackOrder(
            PreferredBackend.npu,
            npuDispatchAvailable: true,
          ))
            backend: clampLitertlmContextTokens(
              requested,
              preferredBackend: backend,
            ),
        };

        expect(perAttempt, {
          PreferredBackend.npu: 896,
          PreferredBackend.gpu: 1024,
          PreferredBackend.cpu: 1024,
        });
      },
    );

    test('values at or above the floor are unchanged on NPU too', () {
      expect(
        clampLitertlmContextTokens(
          1024,
          preferredBackend: PreferredBackend.npu,
        ),
        1024,
      );
      expect(
        clampLitertlmContextTokens(
          4096,
          preferredBackend: PreferredBackend.npu,
        ),
        4096,
      );
    });
  });
}
