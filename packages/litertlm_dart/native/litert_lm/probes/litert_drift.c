// Numeric drift of any `.tflite` between two LiteRT builds. Every signature
// whose tensors have static shapes runs once with inputs filled from a fixed
// pseudo-random sequence of the tensor's type; each output is written to
// <outdir>/<signature>.<output index>.<type>.bin. Running two libraries into
// two directories and comparing the files shows whether, and by how much, a
// model's outputs moved (litert_drift_compare.py). No preprocessing, so it
// covers speech and TTS models as well as embedders; it says nothing about
// output quality, only about change.
//
//   cc -O1 -Wall -I<litert checkout> -I<dir with build_config.h> \
//      -o litert_drift litert_drift.c -ldl
//   litert_drift <lib> <model.tflite> <cpu|gpu> <outdir>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "litert/c/litert_common.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_tensor_buffer.h"

#define FN(name) static __typeof__(&name) p_##name
FN(LiteRtCreateEnvironment);
FN(LiteRtCreateModelFromFile);
FN(LiteRtGetNumModelSignatures);
FN(LiteRtGetModelSignature);
FN(LiteRtGetSignatureKey);
FN(LiteRtGetNumSignatureInputs);
FN(LiteRtGetNumSignatureOutputs);
FN(LiteRtGetSignatureInputTensorByIndex);
FN(LiteRtGetSignatureOutputTensorByIndex);
FN(LiteRtGetRankedTensorType);
FN(LiteRtCreateOptions);
FN(LiteRtSetOptionsHardwareAccelerators);
FN(LiteRtCreateCompiledModel);
FN(LiteRtCreateTensorBufferFromHostMemory);
FN(LiteRtDestroyTensorBuffer);
FN(LiteRtRunCompiledModel);
FN(LiteRtLockTensorBuffer);
FN(LiteRtUnlockTensorBuffer);

static int g_missing = 0;
static void* Load(void* lib, const char* name) {
  void* f = dlsym(lib, name);
  if (!f) {
    fprintf(stderr, "missing export %s\n", name);
    g_missing++;
  }
  return f;
}
#define LOAD(name) p_##name = (__typeof__(p_##name))Load(lib, #name)

static size_t ElementSize(LiteRtElementType t, const char** name) {
  switch (t) {
    case kLiteRtElementTypeFloat32: *name = "f32"; return 4;
    case kLiteRtElementTypeFloat16: *name = "f16"; return 2;
    case kLiteRtElementTypeInt32: *name = "i32"; return 4;
    case kLiteRtElementTypeInt64: *name = "i64"; return 8;
    case kLiteRtElementTypeInt16: *name = "i16"; return 2;
    case kLiteRtElementTypeInt8: *name = "i8"; return 1;
    case kLiteRtElementTypeUInt8: *name = "u8"; return 1;
    case kLiteRtElementTypeBool: *name = "bool"; return 1;
    default: *name = "?"; return 0;
  }
}

static uint32_t g_rng = 12345;
static uint32_t Next(void) {
  g_rng ^= g_rng << 13;
  g_rng ^= g_rng >> 17;
  g_rng ^= g_rng << 5;
  return g_rng;
}
// Values every model takes without leaving its domain: floats in [-1, 1],
// integers (token ids, lengths, positions) in [1, 50], booleans true.
static void Fill(void* data, LiteRtElementType t, size_t n) {
  for (size_t i = 0; i < n; i++) {
    uint32_t r = Next();
    switch (t) {
      case kLiteRtElementTypeFloat32:
        ((float*)data)[i] = (float)((int32_t)(r % 20001) - 10000) / 10000.0f;
        break;
      case kLiteRtElementTypeFloat16: {
        // A half in [-1, 1]: sign, exponent 0..14, mantissa.
        uint16_t h = (uint16_t)(((r & 1) << 15) | ((r >> 1) % 15) << 10 |
                                ((r >> 5) & 0x3ff));
        ((uint16_t*)data)[i] = h;
        break;
      }
      case kLiteRtElementTypeInt32: ((int32_t*)data)[i] = 1 + r % 50; break;
      case kLiteRtElementTypeInt64: ((int64_t*)data)[i] = 1 + r % 50; break;
      case kLiteRtElementTypeInt16: ((int16_t*)data)[i] = 1 + r % 50; break;
      case kLiteRtElementTypeInt8: ((int8_t*)data)[i] = (int8_t)(r % 16); break;
      case kLiteRtElementTypeUInt8: ((uint8_t*)data)[i] = (uint8_t)(r % 16); break;
      case kLiteRtElementTypeBool: ((uint8_t*)data)[i] = 1; break;
      default: break;
    }
  }
}

static bool Static(const LiteRtRankedTensorType* t, size_t* count) {
  *count = 1;
  for (unsigned d = 0; d < t->layout.rank; d++) {
    if (t->layout.dimensions[d] <= 0) return false;
    *count *= (size_t)t->layout.dimensions[d];
  }
  return true;
}

#define CHECK(call)                                                  \
  do {                                                               \
    LiteRtStatus s_ = (call);                                        \
    if (s_ != kLiteRtStatusOk) {                                     \
      printf("RESULT drift FAIL %s status=%d\n", #call, (int)s_);    \
      exit(1);                                                       \
    }                                                                \
  } while (0)

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: %s <lib> <model.tflite> <cpu|gpu> <outdir>\n",
            argv[0]);
    return 64;
  }
  void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    fprintf(stderr, "cannot load %s: %s\n", argv[1], dlerror());
    return 3;
  }
  LOAD(LiteRtCreateEnvironment);
  LOAD(LiteRtCreateModelFromFile);
  LOAD(LiteRtGetNumModelSignatures);
  LOAD(LiteRtGetModelSignature);
  LOAD(LiteRtGetSignatureKey);
  LOAD(LiteRtGetNumSignatureInputs);
  LOAD(LiteRtGetNumSignatureOutputs);
  LOAD(LiteRtGetSignatureInputTensorByIndex);
  LOAD(LiteRtGetSignatureOutputTensorByIndex);
  LOAD(LiteRtGetRankedTensorType);
  LOAD(LiteRtCreateOptions);
  LOAD(LiteRtSetOptionsHardwareAccelerators);
  LOAD(LiteRtCreateCompiledModel);
  LOAD(LiteRtCreateTensorBufferFromHostMemory);
  LOAD(LiteRtDestroyTensorBuffer);
  LOAD(LiteRtRunCompiledModel);
  LOAD(LiteRtLockTensorBuffer);
  LOAD(LiteRtUnlockTensorBuffer);
  if (g_missing) return 4;

  LiteRtEnvironment env = NULL;
  CHECK(p_LiteRtCreateEnvironment(0, NULL, &env));
  LiteRtModel model = NULL;
  CHECK(p_LiteRtCreateModelFromFile(env, argv[2], &model));
  LiteRtOptions options = NULL;
  CHECK(p_LiteRtCreateOptions(&options));
  CHECK(p_LiteRtSetOptionsHardwareAccelerators(
      options, !strcmp(argv[3], "gpu") ? kLiteRtHwAcceleratorGpu
                                       : kLiteRtHwAcceleratorCpu));
  LiteRtCompiledModel compiled = NULL;
  CHECK(p_LiteRtCreateCompiledModel(env, model, options, &compiled));

  LiteRtParamIndex num_sigs = 0;
  CHECK(p_LiteRtGetNumModelSignatures(model, &num_sigs));
  int ran = 0, skipped = 0;
  for (LiteRtParamIndex si = 0; si < num_sigs; si++) {
    LiteRtSignature sig = NULL;
    CHECK(p_LiteRtGetModelSignature(model, si, &sig));
    const char* key = NULL;
    CHECK(p_LiteRtGetSignatureKey(sig, &key));
    LiteRtParamIndex ni = 0, no = 0;
    CHECK(p_LiteRtGetNumSignatureInputs(sig, &ni));
    CHECK(p_LiteRtGetNumSignatureOutputs(sig, &no));
    LiteRtTensorBuffer* in = calloc(ni, sizeof *in);
    LiteRtTensorBuffer* out = calloc(no, sizeof *out);
    void** in_host = calloc(ni, sizeof(void*));
    void** out_host = calloc(no, sizeof(void*));
    LiteRtRankedTensorType* out_types = calloc(no, sizeof *out_types);
    bool ok = true;
    for (LiteRtParamIndex i = 0; i < ni && ok; i++) {
      LiteRtTensor t = NULL;
      LiteRtRankedTensorType rt;
      const char* tn;
      size_t count;
      CHECK(p_LiteRtGetSignatureInputTensorByIndex(sig, i, &t));
      if (p_LiteRtGetRankedTensorType(t, &rt) != kLiteRtStatusOk ||
          !Static(&rt, &count) || !ElementSize(rt.element_type, &tn)) {
        ok = false;
        break;
      }
      size_t bytes = count * ElementSize(rt.element_type, &tn);
      in_host[i] = aligned_alloc(64, (bytes + 63) / 64 * 64);
      Fill(in_host[i], rt.element_type, count);
      CHECK(p_LiteRtCreateTensorBufferFromHostMemory(&rt, in_host[i], bytes,
                                                     NULL, &in[i]));
    }
    for (LiteRtParamIndex o = 0; o < no && ok; o++) {
      LiteRtTensor t = NULL;
      const char* tn;
      size_t count;
      CHECK(p_LiteRtGetSignatureOutputTensorByIndex(sig, o, &t));
      if (p_LiteRtGetRankedTensorType(t, &out_types[o]) != kLiteRtStatusOk ||
          !Static(&out_types[o], &count) ||
          !ElementSize(out_types[o].element_type, &tn)) {
        ok = false;
        break;
      }
      size_t bytes = count * ElementSize(out_types[o].element_type, &tn);
      out_host[o] = aligned_alloc(64, (bytes + 63) / 64 * 64);
      CHECK(p_LiteRtCreateTensorBufferFromHostMemory(
          &out_types[o], out_host[o], bytes, NULL, &out[o]));
    }
    if (!ok) {
      printf("INFO drift signature=%s skipped (dynamic or unsupported type)\n",
             key);
      skipped++;
    } else {
      LiteRtStatus rs = p_LiteRtRunCompiledModel(compiled, si, ni, in, no, out);
      if (rs != kLiteRtStatusOk) {
        printf("RESULT drift_run FAIL signature=%s status=%d\n", key, (int)rs);
      } else {
        for (LiteRtParamIndex o = 0; o < no; o++) {
          const char* tn;
          size_t count;
          Static(&out_types[o], &count);
          size_t bytes = count * ElementSize(out_types[o].element_type, &tn);
          void* locked = NULL;
          CHECK(p_LiteRtLockTensorBuffer(out[o], &locked,
                                         kLiteRtTensorBufferLockModeRead));
          char path[1024];
          snprintf(path, sizeof path, "%s/%s.%zu.%s.bin", argv[4], key,
                   (size_t)o, tn);
          FILE* f = fopen(path, "wb");
          fwrite(locked, 1, bytes, f);
          fclose(f);
          p_LiteRtUnlockTensorBuffer(out[o]);
        }
        printf("INFO drift signature=%s inputs=%zu outputs=%zu\n", key,
               (size_t)ni, (size_t)no);
        ran++;
      }
    }
    for (LiteRtParamIndex i = 0; i < ni; i++) {
      if (in[i]) p_LiteRtDestroyTensorBuffer(in[i]);
      free(in_host[i]);
    }
    for (LiteRtParamIndex o = 0; o < no; o++) {
      if (out[o]) p_LiteRtDestroyTensorBuffer(out[o]);
      free(out_host[o]);
    }
    free(in);
    free(out);
    free(in_host);
    free(out_host);
    free(out_types);
  }
  printf("RESULT drift %s ran=%d skipped=%d signatures=%zu\n",
         ran ? "PASS" : "FAIL", ran, skipped, (size_t)num_sigs);
  return ran ? 0 : 1;
}
