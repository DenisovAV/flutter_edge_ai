// Regression test for #318: a maxTokens below the model's baked
// `kv_cache_max_len` (1024 for every supported .litertlm model) underflows the
// native KV-cache resize and DYNAMIC_UPDATE_SLICE crashes at generation.
// `contextTokensFor` raises any value below the floor up to it on the CPU
// and the GPU; `Engine.create` applies it to the backend it loads.
//
// Reproduced on Pixel 8a (Gemma 4 E2B, CPU): 100/256/512 crash, 1024/4096 work.
@TestOn('vm')
library;

import 'package:litertlm_dart/internal_io.dart';
import 'package:test/test.dart';

void main() {
  group('contextTokensFor (#318)', () {
    test('the floor constant is 1024 (the max known kv_cache_max_len)', () {
      expect(minCpuGpuContextTokens, 1024);
    });

    test('clamps values below the floor up to 1024', () {
      // The user's exact value, plus the verified-crashing thresholds.
      expect(contextTokensFor(100, BackendKind.cpu), 1024);
      expect(contextTokensFor(256, BackendKind.cpu), 1024);
      expect(contextTokensFor(512, BackendKind.cpu), 1024);
      expect(contextTokensFor(1, BackendKind.cpu), 1024);
      expect(contextTokensFor(1023, BackendKind.cpu), 1024);
    });

    test('leaves the floor itself untouched', () {
      expect(contextTokensFor(1024, BackendKind.cpu), 1024);
    });

    test('passes through values above the floor unchanged', () {
      expect(contextTokensFor(2048, BackendKind.cpu), 2048);
      expect(contextTokensFor(4096, BackendKind.cpu), 4096);
      expect(contextTokensFor(8192, BackendKind.cpu), 8192);
    });

    test('handles zero (treated as below the floor)', () {
      expect(contextTokensFor(0, BackendKind.cpu), 1024);
    });

    test('clamps for every backend that is not NPU', () {
      for (final backend in [BackendKind.cpu, BackendKind.gpu]) {
        expect(
          contextTokensFor(512, backend),
          1024,
          reason:
              'the #318 floor is a CPU/GPU fact and still applies to $backend',
        );
      }
    });
  });

  // LiteRT-LM#3508: an NPU bundle is compiled for one cache_length, and a
  // Gemma 3 npu_export build for the Qualcomm NPU keeps every prefill chunk
  // only up to 896 — below the #318 floor. LiteRT-LM's NPU executor lowers a
  // larger value to the bundle's LlmMetadata.max_num_tokens, and to the cache
  // length only when the metadata has none (LiteRT-LM#4184), so a clamped 1024
  // is safe only on a bundle whose metadata matches its cache. The #318 floor
  // is a CPU/GPU fact, and the caller's number passes through.
  group('contextTokensFor leaves NPU alone (LiteRT-LM#3508)', () {
    test('896 — the measured Gemma 3 Qualcomm value — is passed through', () {
      expect(contextTokensFor(896, BackendKind.npu), 896);
    });

    test('every value below the floor survives on NPU', () {
      for (final tokens in [1, 128, 512, 768, 896, 1023]) {
        expect(contextTokensFor(tokens, BackendKind.npu), tokens);
      }
    });

    // The trap this pins: `BackendKind.npu` does not mean the NPU runs.
    // A generic bundle is never tried on the NPU, and a file the load plan
    // cannot read is tried npu -> gpu -> cpu (`ffiBackendFallbackOrder`), so an
    // NPU-sized context below the floor must NOT survive into the GPU and CPU
    // attempts — those are the engines the #318 floor exists for. A bundle
    // compiled for an NPU is tried on the NPU alone (`planLiteRtLmLoad`).
    // Resolving the clamp once from the REQUESTED backend (rather than per
    // attempt) is exactly the regression, and it is invisible on a device that
    // has an NPU.
    test(
      'a fallback from NPU re-applies the floor to the backends after it',
      () {
        const requested = 896; // the measured Gemma 3 Qualcomm cache_length
        final perAttempt = {
          // npu pinned on: this case is about the floor being skipped for npu
          // and applied to whatever follows it, which needs a three-backend
          // chain regardless of whether the test host ships an NPU dispatch.
          for (final backend in ffiBackendFallbackOrder(
            BackendKind.npu,
            npuAvailable: true,
          ))
            backend: contextTokensFor(requested, backend),
        };

        expect(perAttempt, {
          BackendKind.npu: 896,
          BackendKind.gpu: 1024,
          BackendKind.cpu: 1024,
        });
      },
    );

    test('values at or above the floor are unchanged on NPU too', () {
      expect(contextTokensFor(1024, BackendKind.npu), 1024);
      expect(contextTokensFor(4096, BackendKind.npu), 4096);
    });
  });
}
