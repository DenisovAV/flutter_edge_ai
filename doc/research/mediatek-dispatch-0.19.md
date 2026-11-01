# MediaTek NPU on LiteRT-LM 0.19: why the dispatch is refused, and what we can do

2026-11-01, branch `native/litertlm-0.19`. Sources: LiteRT at our 0.18 pin
(`26895c9f`) and our 0.19 pin (`dcb657e8`), Google Maven, Google's
`litertlm-android` 0.19.0 AAR, and the device run in
[litertlm-0.19-phase1.md](litertlm-0.19-phase1.md) (Galaxy Tab S10+, MT6989).

## What fails

On the Tab S10+ with our 0.19 Android build and the dispatch from
`litert-npu-runtime-mediatek` 2.3.0:

```
Could not load symbol LiteRtDispatchQueryInterface: undefined symbol: LiteRtDispatchQueryInterface
No usable Dispatch runtime found
```

## 1. Root cause

The LiteRT commit `f59b79337` ("Migrate the LiteRT Dispatch C ABI to versioned
interface tables", 2026-10-20, Andrew Zhang, `PiperOrigin-RevId: 1003357038`)
changed the Dispatch C ABI. It is a Piper export: there is no GitHub PR, issue or
design doc behind it. The commit before it, `5c752aef7` ("Add ABI headers to LiteRT
accelerator and dispatch structs"), prepared the change. `060bb71d7` is a
follow-up that does not reinitialize the vendor on a second environment. The
commit is not in any LiteRT release: v2.3.0 and v2.3.2 are 534 commits behind it on
a diverged branch. LiteRT-LM v0.19.0 pins `dcb657e8`, so it ships the change.

**Before (0.18 pin)** the library exported
`LiteRtDispatchGetApi(LiteRtDispatchApi*)`. It filled one 56-byte struct:

```
{ LiteRtAbiHeader abi_header; LiteRtApiVersion version;
  LiteRtDispatchInterface* interface; LiteRtDispatchAsyncInterface* async_interface;
  LiteRtDispatchGraphInterface* graph_interface;
  LiteRtCustomTensorBufferHandlersDef* tensor_buffer_handlers_def; }
```

The loader then checked only `version` against `LITERT_API_VERSION` (0.1.0).

**After (0.19 pin)** the library must export
`LiteRtDispatchQueryInterface(id, runtime_version, LiteRtInterface* out)`. It is
asked for four tables by id: basic 0, async 1, graph 2, custom tensor buffer
handlers 3. Each table must start with an `LiteRtAbiHeader` whose `major_version`
is 1 (`LITERT_DISPATCH_ABI_VERSION` 1.0.0), and each table is negotiated through
`litert::internal::NegotiateInterface`. If the symbol is missing,
`LiteRtDispatchInitialize` returns at once
(`litert/runtime/dispatch/litert_dispatch.cc`). When the library exports
`LiteRtDispatchInitialize`, the loader only logs "exports legacy symbol … Please
recompile vendor library against the versioned LiteRT Dispatch C ABI".

**There is no compatibility path.** There is no build flag, env variable, fallback
branch or second loader. The only alternative is
`LiteRtStaticLinkedDispatchQueryInterface`, for dispatches linked into the runtime.

### The two ABIs, field by field

| | 0.18 pin (legacy) | 0.19 pin (V1) |
|---|---|---|
| entry point | `LiteRtDispatchGetApi` | `LiteRtDispatchQueryInterface` |
| basic table | `LiteRtDispatchInterface`: 26 function pointers, `initialize` … `get_hooks`, no header; `attach_edge_buffer`/`detach_edge_buffer` only under `LITERT_ENABLE_FABRIC_INTEGRATION` | `LiteRtDispatchInterface_V1`: `abi_header` + the same 26 pointers in the same order + the two edge-buffer slots, now always present ("capability-gated"), 232 bytes |
| async table | 2 pointers, no header | `abi_header` + the same 2 |
| graph table | 16 pointers (+2 scratchpad slots under fabric), no header | `abi_header` + the same 16 + the 2 scratchpad slots |
| buffer handlers | `LiteRtCustomTensorBufferHandlersDef` (already has `abi_header`, 136 bytes) | `…Def_V1`: the same struct renamed, a typedef keeps the old name |
| function signatures | — | **identical**: every `LiteRtDispatch*T` typedef is unchanged |
| a missing function | NULL slot | NULL slot (`LITERT_ABI_HAS_API` → `kLiteRtStatusErrorUnsupported`) |

What the dispatch calls back is also compatible:

- `LiteRtRuntimeContext` (`litert_runtime_context.h`) is byte-identical at both pins.
- The runtime C API table it points to (`litert_runtime_c_api.h`) only appends
  entries: ABI 1.1.0 → 1.4.0, new members at the end, nothing reordered.
- `litert_common.h` gains `LiteRtInterface`, two handles and
  `kLiteRtStatusErrorFailedPrecondition` (11); none of them moves.
- `litert_tensor_buffer_types.h`, `litert_model_types.h` and
  `vendors/c/litert_dispatch.h` are identical.
- The delegate still calls `check_runtime_compatibility` with
  `LITERT_API_VERSION` 0.1.0, the same value as before.

### Google's MediaTek dispatch (AAR 2.3.2)

- `libLiteRtDispatch_MediaTek.so` exports only `LiteRtDispatchGetApi@@VERS_1.0`.
- It imports nothing from LiteRT: it calls the runtime only through the context
  it is given. `NEEDED` is `libandroid`, `liblog`, `libc`, `libm`, `libdl`.
- `GetApi` copies one static struct: version 0.1.0, abi_header zero.
  `interface` points to a table of 26 slots plus room for the fabric slots.
  `async_interface`, `graph_interface` and `tensor_buffer_handlers_def` are NULL.
- Filled basic slots: `initialize` … `invoke` and `check_runtime_compatibility`.
- NULL basic slots: the metrics slots, `invocation_context_set_options` and
  `get_hooks`. They are NULL in the 0.18 runs too.

## 2. Upstream state (2026-11-01)

**Google's own LiteRT-LM 0.19.0 has the same break.**

- `litertlm-android` 0.19.0's `liblitertlm_jni.so` contains only the
  `LiteRtDispatchQueryInterface` lookup, plus the "legacy symbol" warning text.
- Every NPU runtime Google publishes still exports only `LiteRtDispatchGetApi`:
  `litert-npu-runtime-{mediatek,qualcomm,google-tensor,intel-openvino}` at
  2.3.0 and 2.3.2, the latest on Maven (checked with `llvm-nm` on all four
  2.3.2 AARs).
- So no published Google NPU runtime loads in Google's own 0.19.0 Android SDK.
- The `prebuilt/android_arm64` folder of the LiteRT-LM v0.19.0 tag carries no
  dispatch.
- Neither release note mentions the change.

We are unaffected on Qualcomm, Tensor and Intel, because we build those
dispatches from the pin.

**Maven.** `com.google.ai.edge.litert:litert-npu-runtime-mediatek` has only
`2.3.0` and `2.3.2`. There are no snapshots, and no other group carries a newer
build.

**Issues and PRs.** None found about `LiteRtDispatchQueryInterface`, the versioned
dispatch ABI or this load failure. Searched in google-ai-edge/LiteRT and
LiteRT-LM for: QueryInterface, "No usable Dispatch runtime", mediatek dispatch,
litert-npu-runtime-mediatek, versioned dispatch. Related, but not this break:

- LiteRT #11250, open: the loader takes the first `libLiteRtDispatch*` it finds.
  It matters for the adapter's file name below.
- LiteRT #9482, open: `mediatek_runtime/` is missing from the NPU runtime zip.
- LiteRT-LM #4256, open: MT6989, the second message of a conversation is empty
  on 0.18.1.
- LiteRT-LM #3413, closed: v0.16.0 refused the Neuron v8 dispatch ABI. That is
  NeuroPilot's version check, not this one.

## 3. Options

### (a) Adapter library of our own: recommended, prototype ready

Our `libLiteRtDispatch_MediaTek.so` exports `LiteRtDispatchQueryInterface`. It
opens Google's dispatch, shipped under a name the loader does not match, from
its own directory. On the first query it calls `LiteRtDispatchGetApi` and copies
the legacy tables into V1 tables:

- the same pointers;
- an `abi_header` of `{size, 1, 0, 0}` on each table;
- NULL for the two optional slots;
- the async and graph tables only when the legacy pointer is non-NULL;
- the handlers def passed through as it is, since it already has the header.

The prototype is `mediatek_dispatch_compat.c`, about 100 lines of C11, in
`/private/tmp/claude-501/mtkcompat/`. It is not in the repo yet.

- **NeuroPilot is not needed.** The adapter includes nothing from it and from
  LiteRT only reuses the struct layouts above, so it is our own Apache-2.0
  code. Google's dispatch keeps arriving through the hook, inside the app,
  exactly as today. The licence position does not change.
- **Host test passed.**
  - A fake legacy dispatch was built from the real 0.18-pin header: each slot
    returns its own index.
  - The adapter was queried the way the 0.19 runtime does: real
    `NegotiateInterface` and `LITERT_ABI_HAS_API` from the `dcb657e8` headers.
  - All 26 basic, 2 async and 16 graph slots answered with the right index; the
    optional slots are reported missing; the handlers interface negotiates.
  - Mutations fail as they should: a table shifted by one slot crashes (exit
    139); a missing legacy library fails at the basic interface.
- **Android build.** It cross-builds with NDK r29 for API 24: 7 KB, exports
  only `LiteRtDispatchQueryInterface`, NEEDs `libdl` and `libc`, every PT_LOAD
  aligned to 16 KB.
- **Device run, 2026-11-01 (DDP Galaxy Tab S10+, MT6989, Android 16).** Our 0.19
  Android build with the adapter and the 2.3.2 dispatch renamed
  `libmtk_litert_dispatch_legacy.so`, both in the dispatch dir, with
  `Gemma3-1B-IT_q4_ekv1280_mt6989.litertlm` and `max_num_tokens` 1280:
  - **The NPU loads.** `engine_create` takes 5.9–6.6 s on `npu`. The MediaTek
    dispatch is active: it logs Neuron runtime 8.2.26 and
    `MediaTek GetInputRequirements` for each input. The same SONAME caused no
    collision.
  - **determinism: PASS**, identical greedy text twice.
  - **longprompt: wrong answer** (the fact at the end is lost). This is the
    Gemma 3 NPU problem of #3508, not the dispatch.
  - **tools: fails** at `conversation_create` with "Failed to create
    GemmaModelConstraintProvider". That is the Gemma 3 tool path, not the
    dispatch; 0.18 was not checked with tools on this model.
  - **multiconv: every second-turn answer is empty**, which is LiteRT-LM #4256
    (MT6989, 0.18.1). The NPU's shared state is the other half of it.
  - So the adapter works; what is left are model and executor issues that are
    not ours.
- **Changes on our side.**
  - The hook writes Google's library as `libmtk_litert_dispatch_legacy.so`. The
    name must not contain `libLiteRtDispatch`: the loader matches that substring
    and recurses into subdirectories.
  - The hook adds the adapter, built in our Android native archive (a new
    native tag is needed for 0.19 anyway).
  - `mediatekNpuLibs` lists both files, so `prepareNpuDispatchDir` stages both.
  - `verify_tarball_manifest.sh` and `npu_build_consistency_test.dart` change
    with it, since MediaTek's dispatch was forbidden in the archive until now.
  - No public API changes.
- **Risks.**
  - The legacy library keeps its SONAME `libLiteRtDispatch_MediaTek.so`, the
    same as the adapter's. Bionic opens a path by inode, so this should not
    collide, but the device run has to confirm it. Otherwise the hook rewrites
    the SONAME in the bytes it already handles.
  - A legacy dispatch never reaches the slot `invocation_context_set_options`,
    which is NULL anyway.
  - When Google ships a V1 AAR, the adapter becomes dead weight. The hook can
    then fetch the new AAR and drop the adapter.
- **Effort:** about 1 day including the hook, tests and the device run.

### (b) Patch LiteRT's loader to accept `LiteRtDispatchGetApi`

The same mapping as (a), inside `litert_dispatch.cc`, applied as a `patches=`
entry of the `litert` archive (like `litert_gpu_registry_apple.patch`).

- Pro: no extra file in the app, and it would also accept Google's Qualcomm and
  Tensor AARs.
- Con: a patch on LiteRT's internals that we carry on every pin bump. It must
  apply with zero fuzz to a file upstream is actively changing (two commits in
  October). It also needs an Android libLiteRtLm rebuild for any change.
- It is also exactly what upstream chose not to do.
- **Effort:** about 1 day; more risk at each bump than (a).

### (c) Wait for Google

We would need a `litert-npu-runtime-mediatek` built after `f59b79337`. Google's
own `litertlm-android` 0.19.0 needs one for every vendor, so it should come, but
there is no date and no issue. Until then MediaTek NPU is lost on 0.19.

### (d) Refuse in 2.6.0

`mediatek_npu: true` would fail at build time, or the probe would refuse with a
message naming the AAR. The CHANGELOG and the docs would say MediaTek NPU needs
litertlm 1.19.x. Cheapest, but it removes a platform shipped in 2.5.x. It is
the fallback if (a) fails on the device.

**Recommendation: (a)** (works on the device, above). File the upstream issue (draft below) in parallel, and
drop the adapter when a V1 AAR appears. The next step is a DDP run on
gts10pwifi-36 (MT6989) of:

- the 0.19 Android probe bundle;
- the adapter;
- the renamed AAR 2.3.2 dispatch;
- `gemma-3-1b-it` `…_mt6989` on the NPU: tools, longprompt, determinism.

The run takes about 10 to 15 minutes, and success is the same output as on 0.18.

## 4. Draft upstream issue (LiteRT): not posted

**Title:** Versioned Dispatch ABI (f59b79337) breaks every published
`litert-npu-runtime-*` AAR: LiteRT-LM 0.19.0 cannot load any of them

**Body:**

> LiteRT `f59b79337` ("Migrate the LiteRT Dispatch C ABI to versioned interface
> tables") made `LiteRtDispatchInitialize` resolve only
> `LiteRtDispatchQueryInterface`. LiteRT-LM v0.19.0 pins `dcb657e8`, which
> includes it, and `com.google.ai.edge.litertlm:litertlm-android:0.19.0` looks up
> only that symbol.
>
> Every NPU runtime published on Google Maven still exports only the legacy entry
> point. `llvm-nm -D --defined-only` on the 2.3.2 AARs:
>
> | AAR | exports |
> |---|---|
> | litert-npu-runtime-mediatek 2.3.2 | `LiteRtDispatchGetApi` |
> | litert-npu-runtime-qualcomm 2.3.2 | `LiteRtDispatchGetApi` |
> | litert-npu-runtime-google-tensor 2.3.2 | `LiteRtDispatchGetApi` |
> | litert-npu-runtime-intel-openvino 2.3.2 | `LiteRtDispatchGetApi` |
>
> On a Galaxy Tab S10+ (MT6989, Android 16), a runtime built from `dcb657e8` with
> the 2.3.0 MediaTek dispatch in the dispatch directory fails with:
>
> ```
> Could not load symbol LiteRtDispatchQueryInterface: undefined symbol: LiteRtDispatchQueryInterface
> No usable Dispatch runtime found
> ```
>
> The same model and dispatch run on the NPU with LiteRT `26895c9f` (LiteRT-LM
> v0.18.0).
>
> There is no fallback to `LiteRtDispatchGetApi`. For the MediaTek dispatch,
> building it ourselves is not an option, because it compiles against the
> NeuroPilot SDK.
>
> As far as I can tell, the legacy and V1 tables have the same function
> pointers in the same order with the same signatures; V1 adds the
> `LiteRtAbiHeader` and makes the edge-buffer and scratchpad slots
> unconditional. A loader fallback that wraps `LiteRtDispatchGetApi` into V1
> tables therefore looks cheap.
>
> Could you either:
>
> 1. publish `litert-npu-runtime-*` builds against the versioned ABI (the
>    MediaTek one at least, since only Google can build it), or
> 2. keep a `LiteRtDispatchGetApi` fallback in the loader until they are out?
>
> Is a 2.3.x/2.4 release with V1 dispatches planned to pair with LiteRT-LM
> 0.19?
