#!/bin/bash
# Patch LiteRT-LM C API source to add:
# 1. cc_binary(linkshared=True) target for shared library (Linux dynamic-list
#    + Windows .def whitelist for the symbols our Dart FFI bindings call)
# 2. setters for the four NPU executor flags (use_hw_masking_for_npu etc.)
# 3. GPU smooth-UI knobs — gpu_context_low_priority + kernel_batch_size (#364)
# 4. LiteRT patches: Apple registers only the statically linked GPU
#    accelerator; two LiteRT backports after the v0.20.0 pin
# 16. litert_lm_conversation_rewind_cancelled_turn: a stopped turn is rewound
#     instead of leaving the conversation poisoned
# 17. SentencePiece loads a BPE vocabulary with a NUL-byte piece (#659); on
#     v0.19.0 a second patch on top of upstream's, which accepts only "\0"
# 26. ThinkingBudgetConstraint copies a user bitmap by data() and vocabulary
#     size (up to native-v0.19.1 the bitmap came from Google's libc++ provider)
#
# 28. Apple: Metal argument buffers stay on (Gemma 4 kernels exceed 31 slots)
# 29. Tool-call constraints from LLGuidance (every tool_choice), not FST
# 30. Windows: c/engine.cc builds with MSVC (no #if inside a macro's arguments)
# 31. FunctionGemma: tool-call arguments in the declared order under LLGuidance
#
# v0.20.0 migration: sections 15, 22, 24 and 27 are anchors only now (upstream
# a48771d2, 9738e180, e0dcad4e and 3db1cfd0ab ship what they patched); section
# 10b drops the Google Tensor dispatch and Intel GlobalGraph v3 backports (in
# the LiteRT pin bf49eb62) and adds two LiteRT backports after that pin
# (aa9e40cd5, 95d3d567b). Section 12 (the Linux ABI bridge to Google's prebuilt
# Gemma constraint provider, #551) is deleted: with section 29 the Gemma data
# processors build their tool-call constraints with LLGuidance, the code it
# bridged is compiled out (LITERT_LM_USE_FST_TOOL_CALL_CONSTRAINTS unset), and
# no provider is linked or shipped. Section 13 (TFLiteWeights read by path on
# Linux and Windows) is deleted too: it kept a C++ map from crossing into
# Google's prebuilt libLiteRt, which no longer ships (both platforms build
# libLiteRt from source with the runtime's own standard library and, on
# Windows, CRT). A Linux x64 build without it gave bit-identical EmbeddingGemma
# 2 270m/440m/740m vectors on CPU and GPU (texts, images, audio) and passed
# Gemma 4 E2B text, images, audio, tools, thinking and stop-rewind on both
# (T4 VM, CI run 45664837300, 2026-11-26); Windows had compiled it out since
# decision D9. Its anchor checks went with it: they guarded the assumptions of
# the rewrite, and the in-memory weight map they kept out is safe to hand over
# to a libLiteRt of the same build.
#
# v0.17.0 migration: section 11 (minizip/zlib mirror) was deleted — upstream's
# WORKSPACE now ships `urls = [tensorflow mirror, mirror.bazel.build,
# zlib.net]`, which is exactly what that section existed to add. It had become
# a permanent WARN, and a patcher that always warns is one whose warnings
# nobody reads.
#
# v0.14.0 migration (Phase 0): upstream 80f301f natively added a per-session
# sampler C API, set_max_num_images, set_litert_dispatch_lib_dir, set_cache_dir
# propagation, and the no-arg create()+setter conversation-config pattern —
# this obsoleted the former sections 2/3/4/5/6/7/8/9 of this script (they
# duplicated/monkey-patched now-native functionality, and two of them targeted
# session_basic.cc internals upstream deleted). Removed at the bump; kept
# section numbers below are the surviving originals, not renumbered.
#
# Usage: patch_c_api.sh <litert_lm_dir>
# Example: patch_c_api.sh /tmp/LiteRT-LM

set -euo pipefail

DIR="${1:?Usage: patch_c_api.sh <litert_lm_dir>}"

echo "Patching LiteRT-LM C API in $DIR..."

# ── 1. Add shared library target to c/BUILD ──
# On Linux, use --dynamic-list (Google's own pattern from
# runtime/engine/litert_lm_main.exported_symbols) to extend the dynamic
# export set with LiteRt*/litert_lm_* while keeping internal symbols
# visible — the WebGPU accelerator plugin needs to resolve LiteRt* C API
# via dlsym(RTLD_DEFAULT) during auto-registration.
#
# Requires building with --define=litert_runtime_link_mode=dynamic so that
# libLiteRtLm references libLiteRt dynamically at runtime instead of statically
# linking the LiteRt C API, which would put two copies of the runtime in the
# process alongside the prebuilt accelerator.
#
# NOT litert_link_capi_so=true. Upstream deleted that name; no config_setting
# reads it, and Bazel accepts unknown --defines silently, so passing it links
# statically while looking correct. That is what broke Windows GPU from
# v0.14.0 (when Dawn was split into its own library) through v0.16.0 — and was
# misreported upstream as LiteRT-LM #2957 before the cause turned out to be
# ours. The live name is documented in upstream's
# docs/getting-started/build-and-run.md as required for GPU. Its old companion,
# resolve_symbols_in_exec, was deleted in LiteRT fd031ae5 (the v0.18.0 pin).
if ! grep -q '"libLiteRtLm.dylib"' "$DIR/c/BUILD"; then
  # Dynamic-list: make these symbols visible in the dynamic export table.
  cat > "$DIR/c/dynamic_list.lds" << 'LDSEOF'
{
  LiteRt*;
  litert_lm_*;
};
LDSEOF

  # Windows .def: whitelist of symbols to export from LiteRtLm.dll.
  # Derived from lib/src/ffi/litert_lm_bindings.dart lookupFunction calls.
  # The EmbeddingEngine C API leaves the DLL through LITERT_LM_C_API_EXPORT;
  # the two response getters section 14 adds are also named here, so a tree
  # that lost section 14 fails the Windows link instead of shipping without.
  # The three stream-chunk accessors are named for the same reason: the Dart
  # client resolves them with GetProcAddress on this DLL and hands them to
  # stream_proxy_create_v1, which refuses to build a proxy without all three, so a
  # tree that stopped exporting them should fail the link, not ship a client that
  # throws on the first send. Section 16's rewind is named for the same reason.
  cat > "$DIR/c/windows_exports.def" << 'DEFEOF'
LIBRARY "LiteRtLm"
EXPORTS
  litert_lm_benchmark_info_delete
  litert_lm_benchmark_info_get_decode_token_count_at
  litert_lm_benchmark_info_get_decode_tokens_per_sec_at
  litert_lm_benchmark_info_get_num_decode_turns
  litert_lm_benchmark_info_get_num_prefill_turns
  litert_lm_benchmark_info_get_prefill_token_count_at
  litert_lm_benchmark_info_get_prefill_tokens_per_sec_at
  litert_lm_benchmark_info_get_time_to_first_token
  litert_lm_benchmark_info_get_total_init_time_in_second
  litert_lm_conversation_cancel_process
  litert_lm_conversation_config_create
  litert_lm_conversation_config_delete
  litert_lm_conversation_config_set_enable_constrained_decoding
  litert_lm_conversation_config_set_extra_context
  litert_lm_conversation_config_set_messages
  litert_lm_conversation_config_set_session_config
  litert_lm_conversation_config_set_system_message
  litert_lm_conversation_config_set_tools
  litert_lm_conversation_create
  litert_lm_conversation_delete
  litert_lm_conversation_get_benchmark_info
  litert_lm_conversation_get_last_turn_end
  litert_lm_conversation_rewind_cancelled_turn
  litert_lm_conversation_send_message
  litert_lm_conversation_send_message_stream
  litert_lm_embedding_response_get_input_length
  litert_lm_embedding_response_get_truncated_length
  litert_lm_engine_create
  litert_lm_engine_create_session
  litert_lm_engine_delete
  litert_lm_engine_settings_create
  litert_lm_engine_settings_delete
  litert_lm_engine_settings_enable_benchmark
  litert_lm_engine_settings_set_activation_data_type
  litert_lm_engine_settings_set_cache_dir
  litert_lm_engine_settings_set_enable_speculative_decoding
  litert_lm_engine_settings_set_gpu_context_low_priority
  litert_lm_engine_settings_set_kernel_batch_size
  litert_lm_engine_settings_set_litert_dispatch_lib_dir
  litert_lm_engine_settings_set_max_num_images
  litert_lm_engine_settings_set_max_num_tokens
  litert_lm_engine_settings_set_num_decode_tokens
  litert_lm_engine_settings_set_num_prefill_tokens
  litert_lm_engine_settings_set_parallel_file_section_loading
  litert_lm_engine_settings_set_prefill_chunk_size
  litert_lm_engine_settings_set_enable_neon_for_npu_greedy_sampling
  litert_lm_engine_settings_set_use_hw_cache_update_for_npu
  litert_lm_engine_settings_set_use_hw_masking_for_npu
  litert_lm_engine_settings_set_use_hw_ple_for_npu
  litert_lm_json_response_delete
  litert_lm_json_response_get_string
  litert_lm_responses_delete
  litert_lm_responses_get_num_candidates
  litert_lm_responses_get_response_text_at
  litert_lm_sampler_params_create
  litert_lm_sampler_params_delete
  litert_lm_sampler_params_set_seed
  litert_lm_sampler_params_set_temperature
  litert_lm_sampler_params_set_top_k
  litert_lm_sampler_params_set_top_p
  litert_lm_session_config_create
  litert_lm_session_config_delete
  litert_lm_session_config_set_apply_prompt_template
  litert_lm_session_config_set_audio_lora_path
  litert_lm_session_config_set_lora_path
  litert_lm_session_config_set_max_output_tokens
  litert_lm_session_config_set_sampler_params
  litert_lm_session_delete
  litert_lm_session_generate_content
  litert_lm_session_generate_content_stream
  litert_lm_session_get_benchmark_info
  litert_lm_set_min_log_level
  litert_lm_stream_chunk_get_error
  litert_lm_stream_chunk_get_text
  litert_lm_stream_chunk_is_final
DEFEOF

  cat >> "$DIR/c/BUILD" << 'BUILDEOF'

cc_binary(
    name = "libLiteRtLm.dylib",
    linkshared = True,
    # Pass .def file via win_def_file (Bazel native Windows attribute) —
    # linkopts /DEF: doesn't work because bazel's MSVC link.exe action
    # already owns the linker invocation and will clobber stray /DEF flags.
    win_def_file = "windows_exports.def",
    linkopts = select({
        "@platforms//os:macos": ["-Wl,-exported_symbol,_LiteRt*", "-Wl,-exported_symbol,_litert_lm_*"],
        "@platforms//os:ios": ["-Wl,-exported_symbol,_LiteRt*", "-Wl,-exported_symbol,_litert_lm_*"],
        "@platforms//os:linux": [
            "-Wl,--dynamic-list=$(location :dynamic_list.lds)",
        ],
        "//conditions:default": [],
    }),
    additional_linker_inputs = select({
        "@platforms//os:linux": [":dynamic_list.lds"],
        "//conditions:default": [],
    }),
    visibility = ["//visibility:public"],
    deps = [":engine"],
)

exports_files(["dynamic_list.lds", "windows_exports.def"])
BUILDEOF
  echo "  OK: Added cc_binary(linkshared=True) to c/BUILD with Linux dynamic-list + Windows .def"
else
  echo "  SKIP: c/BUILD already has shared lib target"
fi

# ── 4b. NPU executor flags: setters for the four NpuConfig options ──
# LiteRT-LM's NPU executor has four hand-written components: NEON greedy
# sampling, the mask update, the KV-cache update and the per-layer embedding
# lookup. Up to v0.19.1 all four defaulted to on, and this section added a
# setter for the mask only: Intel LunarLake/PantherLake needs it off (the HW
# mask path ended engine_create with 0xC0000409), and Intel's Gemma 4 26B for
# Panther Lake needs it on (npu_vendor_host.dart). v0.20.0 (fd79fb15) makes
# each an optional resolved from the bundle's LlmNpuExecutorMetadata, else off,
# and still exposes none in the C API. So every flag gets a setter here: until
# the new defaults are measured per vendor (0.20 migration decision D5) the
# Dart side passes the 0.19 values explicitly. An unset flag keeps upstream's
# resolution (metadata, else off).
NPU_FLAGS="enable_neon_for_npu_greedy_sampling use_hw_masking_for_npu use_hw_cache_update_for_npu use_hw_ple_for_npu"
grep -q 'std::optional<bool> use_hw_masking_for_npu' "$DIR/runtime/executor/llm_executor_settings.h" || {
  echo "  ERROR: section 4b: NpuConfig's flags are no longer std::optional<bool>" >&2
  exit 1
}
for flag in $NPU_FLAGS; do
  grep -q "std::optional<bool> $flag = std::nullopt;" "$DIR/runtime/executor/llm_executor_settings.h" || {
    echo "  ERROR: section 4b: NpuConfig has no optional $flag" >&2
    exit 1
  }
  if ! grep -q "litert_lm_engine_settings_set_$flag(" "$DIR/c/engine.h"; then
    sed -i.bak "/Creates a LiteRT LM Engine from the given settings/i\\
// Sets NpuConfig.$flag on the main executor (patch_c_api.sh section 4b).\\
// Unset, LiteRT-LM takes it from the bundle's NPU executor metadata, else off.\\
LITERT_LM_C_API_EXPORT\\
LiteRtLmStatusCode litert_lm_engine_settings_set_$flag(\\
    LiteRtLmEngineSettings* settings, bool value);\\
" "$DIR/c/engine.h"
    rm -f "$DIR/c/engine.h.bak"
  fi
  if ! grep -q "^LiteRtLmStatusCode litert_lm_engine_settings_set_$flag(" "$DIR/c/engine.cc"; then
    sed -i.bak "/^LiteRtLmStatusCode litert_lm_engine_settings_set_activation_data_type(/i\\
LiteRtLmStatusCode litert_lm_engine_settings_set_$flag(\\
    LiteRtLmEngineSettings* settings, bool value) {\\
  if (!IsValidEngineSettings(settings)) {\\
    return kLiteRtLmStatusInvalidArgument;\\
  }\\
  auto\\& exec = settings->settings->GetMutableMainExecutorSettings();\\
  litert::lm::NpuConfig config;\\
  auto current = exec.GetBackendConfig<litert::lm::NpuConfig>();\\
  if (current.ok()) {\\
    config = *current;\\
  }\\
  config.$flag = value;\\
  exec.SetBackendConfig(config);\\
  return kLiteRtLmStatusOk;\\
}\\
\\
" "$DIR/c/engine.cc"
    rm -f "$DIR/c/engine.cc.bak"
  fi
  grep -q "litert_lm_engine_settings_set_$flag(" "$DIR/c/engine.h" &&
    grep -q "^LiteRtLmStatusCode litert_lm_engine_settings_set_$flag(" "$DIR/c/engine.cc" || {
    echo "  ERROR: section 4b: an anchor moved; no set_$flag" >&2
    exit 1
  }
  echo "  OK: litert_lm_engine_settings_set_$flag"
done

# ── 4c. Add GPU smooth-UI knobs — gpu_context_low_priority + kernel_batch_size ──
# #364: on Android/OpenCL a GPU prefill monopolizes the Adreno GPU and starves
# the Flutter raster/compositor thread (repro'd on S23 Ultra: raster p95
# 6.8ms->123ms during a ~2s prefill). AdvancedSettings.gpu_context_low_priority
# lowers the inference GPU context priority (SetPriority(kLow)); hint_kernel_batch_size
# adds periodic GPU flushes so the compositor gets scheduling windows. Both are
# consumed at a0afb5a in llm_executor_settings_utils.cc:210-223 but the upstream
# C API doesn't expose them. Mirror the upstream set_enable_speculative_decoding
# idiom (engine.cc:500-509).
if ! grep -q "set_gpu_context_low_priority" "$DIR/c/engine.h"; then
  sed -i.bak '/Creates a LiteRT LM Engine from the given settings/i\
// Lowers the GPU inference context priority (OpenCL kLow) so on-device GPU\
// prefill/decode does not starve the host UI compositor (#364). GPU-only;\
// a no-op on backends whose delegate ignores context priority.\
LITERT_LM_C_API_EXPORT\
LiteRtLmStatusCode litert_lm_engine_settings_set_gpu_context_low_priority(\
    LiteRtLmEngineSettings* settings, bool value);\
\
// Hints a GPU kernel batch size so the delegate periodically flushes, giving\
// the UI compositor scheduling windows during long GPU work (#364).\
LITERT_LM_C_API_EXPORT\
LiteRtLmStatusCode litert_lm_engine_settings_set_kernel_batch_size(\
    LiteRtLmEngineSettings* settings, int kernel_batch_size);\
' "$DIR/c/engine.h"
  rm -f "$DIR/c/engine.h.bak"
  echo "  OK: Added GPU smooth-UI knob setters to c/engine.h"
else
  echo "  SKIP: c/engine.h already has set_gpu_context_low_priority"
fi

if ! grep -q "set_gpu_context_low_priority" "$DIR/c/engine.cc"; then
  sed -i.bak '/^LiteRtLmStatusCode litert_lm_engine_settings_set_activation_data_type(/i\
LiteRtLmStatusCode litert_lm_engine_settings_set_gpu_context_low_priority(\
    LiteRtLmEngineSettings* settings, bool value) {\
  if (!IsValidEngineSettings(settings)) {\
    return kLiteRtLmStatusInvalidArgument;\
  }\
  auto\& main_settings = settings->settings->GetMutableMainExecutorSettings();\
  auto advanced_settings = main_settings.GetAdvancedSettings().value_or(\
      litert::lm::AdvancedSettings());\
  advanced_settings.gpu_context_low_priority = value;\
  main_settings.SetAdvancedSettings(advanced_settings);\
  return kLiteRtLmStatusOk;\
}\
\
LiteRtLmStatusCode litert_lm_engine_settings_set_kernel_batch_size(\
    LiteRtLmEngineSettings* settings, int kernel_batch_size) {\
  if (!IsValidEngineSettings(settings)) {\
    return kLiteRtLmStatusInvalidArgument;\
  }\
  auto\& main_settings = settings->settings->GetMutableMainExecutorSettings();\
  auto advanced_settings = main_settings.GetAdvancedSettings().value_or(\
      litert::lm::AdvancedSettings());\
  advanced_settings.hint_kernel_batch_size = kernel_batch_size;\
  main_settings.SetAdvancedSettings(advanced_settings);\
  return kLiteRtLmStatusOk;\
}\
\
' "$DIR/c/engine.cc"
  rm -f "$DIR/c/engine.cc.bak"
  for fn in set_gpu_context_low_priority set_kernel_batch_size; do
    grep -q "^LiteRtLmStatusCode litert_lm_engine_settings_${fn}(" "$DIR/c/engine.cc" || {
      echo "  ERROR: section 4c: the set_activation_data_type anchor moved; no $fn" >&2
      exit 1
    }
  done
  echo "  OK: Added GPU smooth-UI knob impls to c/engine.cc"
else
  echo "  SKIP: c/engine.cc already has set_gpu_context_low_priority"
fi

# ── 10. Apple GPU: no accelerator or sampler library is dlopened ──
#
# Native Assets bundles each dylib as `<X>.framework/<X>`, so a dlopen by
# basename finds nothing in an Apple app (and the old lib*.dylib symlinks were
# App Store ITMS-90432). Up to native-v0.19.1 section 10b rewrote LiteRT's
# Metal accelerator dlopen to our LiteRtLmMetalAccelerator.framework path (a
# name of our own: flutter_litert >= 3.4.0 ships LiteRtMetalAccelerator.framework
# for its own LiteRT, and an app holds one framework per name). From v0.20.0
# libLiteRtLm links the Metal accelerator in, so 10b compiles the dlopen path
# out on Apple instead (patches/litert_gpu_registry_apple.patch).

# 10a. sampler_factory.cc — DELIBERATELY NOT PATCHED.
#
# Patching the Metal sampler dlopen to find the framework binary was tried and
# crashed: EXC_BAD_ACCESS deep inside the inference pipeline (iPhone 16 Pro,
# Gemma 4 E2B GPU, temperature=0.0, 2026-04-30). The cause recorded at the time
# was a sampler dylib exporting only 3 of the 7 C ABI functions sampler_factory
# expects, so dlsym for UpdateConfig returned NULL and a later call through the
# half-built sampler vtable dereferenced uninitialized memory.
#
# That cause does not hold for the prebuilts this script now builds against:
# upstream's libLiteRtTopKMetalSampler.dylib exports 7 of 7 at v0.16.0 (macOS)
# and at v0.17.0 (macOS and iOS). The 3-of-7 dylib in upstream #2073 is the
# WebGPU sampler, which went from 3 to 7 exports in v0.17.0. Enabling the Metal
# GPU sampler therefore needs a fresh device run, not a wait for upstream.
#
# Until then, leaving the original "libLiteRtTopKMetalSampler.dylib" basename
# means dlopen on Apple cannot resolve it (Native Assets bundles a framework,
# not a flat .dylib), so sampler_factory.cc falls back to the CPU sampling
# path — same behavior we had pre-0.14.1. Inference still runs on the GPU
# accelerator; only the per-token argmax happens on CPU (~1-5 ms/token).

# 10b. LiteRT patches. gpu_registry.cc and the two backports live in LiteRT, a
# transitive Bazel dependency: the litert http_archive gets a `patches` list
# (applied at fetch, before upstream's own patch_cmds), and Bazel fails the
# fetch when a hunk does not apply — the loud failure a moved upstream line
# has to produce.
#   - patches/litert_gpu_registry_apple.patch: on Apple only the accelerator
#     linked into libLiteRtLm is registered and no accelerator library is ever
#     dlopened (flutter_litert in the same app; D1 of the 0.20 migration: no
#     Metal framework ships). Up to native-v0.19.1 this section also rewrote
#     the dlopen name to our framework path with a sed in patch_cmds; there is
#     nothing to dlopen now, so that is gone.
#   - patches/litert_libLiteRt_static_crt.patch (ours, Windows only in
#     effect): drops `features = ["-static_link_msvcrt"]` from libLiteRt's
#     cc_binary, so our --features=static_link_msvcrt builds libLiteRt.dll /MT
#     like LiteRtLm.dll and it imports no VC++ runtime. Upstream's /MD
#     libLiteRt.dll imports VCRUNTIME140_THREADS.dll (C11 threads, VC++ 14.38+),
#     the #456 failure on a machine without a recent redistributable and in
#     every plain Dart program, which ships none (D9).
#   - patches/litert_webgpu_stage_spatial_bindings.patch: LiteRT aa9e40cd5
#     (LiteRT-LM #4460, WebGPU prefill_8 on Windows D3D12 and Linux Vulkan).
#   - patches/litert_adreno_flash_decode_keys.patch: LiteRT 95d3d567b
#     (Gemma 4 float32 on Adreno 8xx).
#   - patches/litert_adreno_gen8_fp32_watchdog.patch: LiteRT 435efa884
#     (withdraws 12ec5f18d's Adreno 8xx FP32 kernel change).
#   - patches/litert_ocl_ahwb_import_arm_only.patch: LiteRT 4be73079f
#     (Exynos/Xclipse OpenCL SIGSEGV, LiteRT-LM #4423).
#   - patches/litert_intel_webgpu_no_dp4a.patch: LiteRT aec6afeb85, which
#     upstream reverted (9d3824510e) before the pin: no int8 src-quantized
#     (dp4a) FC/conv on an Intel GPU, whose outputs are corrupted on D3D12
#     (Gemma 4 12B answered no text on Panther Lake, LiteRT-LM #4083). Drop it
#     once the dp4a path is fixed upstream, not when the pin moves.
# The backports are after the v0.20.0 LiteRT pin bf49eb62; drop each once
# the pin contains its commit. The pin already has the Google Tensor dispatch
# OSS hooks change and OpenVINO GlobalGraph v3 (cac3c771e), whose backports
# this list carried up to native-v0.19.1.
LITERT_PATCHES=(
  litert_gpu_registry_apple
  litert_libLiteRt_static_crt
  litert_webgpu_stage_spatial_bindings
  litert_adreno_flash_decode_keys
  litert_adreno_gen8_fp32_watchdog
  litert_ocl_ahwb_import_arm_only
  litert_intel_webgpu_no_dp4a
)
export WORKSPACE_FILE="$DIR/WORKSPACE"
export LITERT_PATCH_LABELS="$(printf '//:flutter_gemma_%s.patch ' "${LITERT_PATCHES[@]}")"
[ -f "$WORKSPACE_FILE" ] || { echo "  ERROR: $WORKSPACE_FILE not found; section 10b cannot apply" >&2; exit 1; }
python3 << 'PYEOF2'
import os, re
ws = os.environ['WORKSPACE_FILE']
labels = os.environ['LITERT_PATCH_LABELS'].split()
with open(ws) as f:
    content = f.read()
name_idx = content.find('    name = "litert",\n')
if name_idx < 0:
    raise SystemExit("  ERROR: section 10b: no litert http_archive in WORKSPACE")
end_idx = content.find('\n)', name_idx)
block = content[name_idx:end_idx]
queued = re.findall(r'"(//:flutter_gemma_[a-z0-9_]+\.patch)"', block)
if queued:
    # A tree this script patched before. Its list must be exactly ours: an
    # older script's list names backports the pin already contains, which
    # would fail the fetch (or worse, a sed this version no longer expects).
    if queued != labels:
        raise SystemExit("  ERROR: section 10b: WORKSPACE queues %s, want %s; "
                         "start from a fresh LiteRT-LM tree" % (queued, labels))
    print("  SKIP: litert archive already queues our patches")
else:
    if 'patches = [' in block:
        raise SystemExit("  ERROR: section 10b: the litert archive has upstream "
                         "patches now; merge our list into it")
    entries = ''.join('        "%s",\n' % l for l in labels)
    content = content.replace(
        '    name = "litert",\n',
        '    name = "litert",\n    patches = [\n' + entries + '    ],\n'
        '    patch_args = ["-p1"],\n', 1)
    with open(ws, 'w') as f:
        f.write(content)
    for l in labels:
        print("  OK: litert archive applies patches/%s"
              % l.replace('//:flutter_gemma_', ''))
PYEOF2
for name in "${LITERT_PATCHES[@]}"; do
  cp "$(cd "$(dirname "$0")" && pwd)/patches/$name.patch" "$DIR/flutter_gemma_$name.patch"
done

# ── 11. Qualcomm NPU options on Linux (HTP burst) ──
#
# CreateLiteRtNpuOptions (runtime/executor/npu/) sets the Qualcomm options —
# HTP burst mode, log level — under `#if defined(__ANDROID__)` only (upstream
# "Bug: 498622107"). On a Linux Qualcomm board (QCS8275) the dispatch then logs
# "Null Qualcomm options" and runs HTP in its default mode: Gemma 4 E2B decoded
# at 16.6 tok/s against the model card's 31.7. The vision executor already sets
# burst on every OS. A real diff, not a sed: when upstream moves this code the
# patch stops applying and the build fails here, instead of shipping unpatched.
NPU_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/npu_qualcomm_options_linux.patch"
if git -C "$DIR" apply --check "$NPU_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$NPU_PATCH"
  echo "  OK: Qualcomm NPU options apply on Linux too (HTP burst)"
elif git -C "$DIR" apply --reverse --check "$NPU_PATCH" 2>/dev/null; then
  echo "  SKIP: Qualcomm NPU options patch already applied"
else
  echo "  ERROR: $NPU_PATCH does not apply to this LiteRT-LM revision —" >&2
  echo "         CreateLiteRtNpuOptions moved; re-create the patch against it." >&2
  exit 1
fi

# ── 14. EmbeddingEngine response lengths (EmbeddingGemma 2) ──
# EmbeddingEngineImpl fills EmbeddingResponse.input_length and
# .truncated_length (runtime/core/embedding_engine_impl.cc), but the C API
# returns only the vector, so a caller cannot tell a truncated input from a
# whole one without tokenizing it again. Two getters, exported on every
# platform (LITERT_LM_C_API_EXPORT, and section 1's Windows .def):
#   litert_lm_embedding_response_get_input_length     -1 for NULL
#   litert_lm_embedding_response_get_truncated_length 0 when not truncated,
#                                                     -1 for NULL
# A real diff, applied like section 11, plus an anchor on the two fields it
# reads still being filled.
EMB_LEN_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/embedding_response_lengths.patch"
if git -C "$DIR" apply --check "$EMB_LEN_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$EMB_LEN_PATCH"
  echo "  OK: embedding responses report input and truncated lengths"
elif git -C "$DIR" apply --reverse --check "$EMB_LEN_PATCH" 2>/dev/null; then
  echo "  SKIP: embedding response lengths already applied"
else
  echo "  ERROR: $EMB_LEN_PATCH does not apply to this LiteRT-LM revision —" >&2
  echo "         c/embedding_engine.{h,cc} moved; re-create the patch against it." >&2
  exit 1
fi
EMB_IMPL="$DIR/runtime/core/embedding_engine_impl.cc"
for field in input_length truncated_length; do
  grep -qF "response.$field = embedding_output.$field;" "$EMB_IMPL" || {
    echo "  ERROR: section 14: EmbeddingEngineImpl no longer fills response.$field" >&2
    exit 1
  }
done

# ── 15. Windows: no C runtime descriptor crosses into libLiteRt.dll ──
# Since LiteRT-LM 9589b6b4 (first in v0.17.0) a bundle with a non-empty
# TF_LITE_AUX (every AOT NPU bundle) is loaded file-backed: a CRT descriptor
# reaches libLiteRt.dll, which links its own CRT, and the process ended with
# 0xC0000409 (LiteRT-LM #4023). Our patch for it is gone: upstream a48771d2
# (in v0.20.0) returns Unimplemented from CreateModelFromFileSection under
# `_WIN32 && LITERT_DYNAMIC_RUNTIME`, and the caller falls back to
# buffer-backed loading. Anchors only: the guard must be there, the only
# descriptor call must stay behind it, and the define must reach the file
# through @litert//litert/cc:litert_model (LiteRT puts LITERT_DYNAMIC_RUNTIME
# on that target under litert_runtime_link_mode=dynamic, which our Windows
# build sets). A guard whose define never arrives is the old crash.
MRL="$DIR/runtime/components/model_resources_litert_lm.cc"
grep -q 'defined(_WIN32) && defined(LITERT_DYNAMIC_RUNTIME)' "$MRL" || {
  echo "  ERROR: section 15: upstream's Windows buffer-backed fallback is gone from $MRL" >&2
  exit 1
}
nofd_callers="$(grep -rlE 'CreateLiteRtModelFromFd\(|LiteRtCreateModelFromFd\(|CreateFromFd\(' \
  --include='*.cc' "$DIR/runtime" "$DIR/c" | grep -v '_test\.cc$' | sed "s|^$DIR/||" | sort | tr '\n' ' ')"
[ "$nofd_callers" = "runtime/components/model_resources.cc runtime/components/model_resources_litert_lm.cc " ] || {
  echo "  ERROR: section 15: unexpected CreateFromFd callers: $nofd_callers" >&2
  exit 1
}
awk '/name = "model_resources_litert_lm"/,/^\)/' "$DIR/runtime/components/BUILD" \
  | grep -q '"@litert//litert/cc:litert_model"' || {
  echo "  ERROR: section 15: model_resources_litert_lm no longer depends on" \
    "@litert//litert/cc:litert_model, which carries LITERT_DYNAMIC_RUNTIME" >&2
  exit 1
}
echo "  OK: section 15: Windows loads AOT sections buffer-backed (upstream a48771d2)"

# ── 16. Rewind a cancelled conversation turn ──
# Conversation::CancelProcess leaves the session poisoned: every later task
# depends on the cancelled one and ends as cancelled too, so after "stop" the
# conversation answers nothing (upstream documents it as unsupported, still so
# on main). A session can undo that — RewindToCheckpoint restores the step and
# the task dependencies — but the Conversation hides its session. The patch:
# - saves a checkpoint right before each send's own prefill (after a thinking
#   refill, whose own rewind would otherwise erase it);
# - records in the C wrapper how each send ended (completed, cancelled,
#   failed), numbered so a late callback of an older send cannot overwrite it;
# - adds litert_lm_conversation_rewind_cancelled_turn (LITERT_LM_C_API_EXPORT,
#   and section 1's Windows .def): cancel whatever still runs, wait until every
#   task has ended (Conversation::WaitUntilDone, upstream since v0.19.0),
#   and only then decide — completed: nothing to do; cancelled: rewind to the
#   checkpoint and prefill the stopped exchange without decoding; anything
#   else: the caller deletes the conversation. Deciding before the wait read a
#   cancel that had not landed yet as "not cancelled" (#682 review).
# The NPU executor rolls back one token at most, so the rewind fails there;
# the Dart client does not call it on the NPU and rebuilds instead.
#
# A real diff, applied like section 11, plus anchors on what it relies on: a
# moved upstream line fails the build here, not a user's next turn.
REWIND_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/conversation_rewind_cancelled_turn.patch"
if git -C "$DIR" apply --check "$REWIND_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$REWIND_PATCH"
  echo "  OK: a cancelled conversation turn can be rewound"
elif git -C "$DIR" apply --reverse --check "$REWIND_PATCH" 2>/dev/null; then
  echo "  SKIP: cancelled-turn rewind already applied"
else
  echo "  ERROR: $REWIND_PATCH does not apply to this LiteRT-LM revision —" >&2
  echo "         runtime/conversation/conversation.{h,cc} or" >&2
  echo "         c/conversation{.h,.cc,_internal.h} moved (re-create the patch)," >&2
  echo "         or the tree carries an older version of it (start from a clean" >&2
  echo "         checkout)." >&2
  git -C "$DIR" apply --check "$REWIND_PATCH" >&2 || true
  exit 1
fi
rewind_fail() {
  echo "  ERROR: section 16: $1" >&2
  exit 1
}
grep -qF 'absl::Status RewindCancelledTurn(' \
  "$DIR/runtime/conversation/conversation.h" ||
  rewind_fail "Conversation::RewindCancelledTurn is not in the tree after applying"
# The rewind un-poisons the session only because the checkpoint carries the
# task dependencies back; without that every later task still ends cancelled.
grep -qF 'last_task_ids_ = it->second.last_task_ids;' \
  "$DIR/runtime/core/session_advanced.cc" ||
  rewind_fail "SessionAdvanced::RewindToCheckpoint no longer restores last_task_ids_"
# The wait must not open before the callbacks have run: Conversation's
# WaitUntilDone is the session's, which waits for its active-task list to
# empty and, since v0.20.0 (4b63acd7), for its callbacks still queued
# (pending_callback_sessions_); a task's end state is now set before its
# callback runs, so the second condition is the one that matters.
grep -qF 'return execution_manager_lock->WaitUntilSessionDone(' \
  "$DIR/runtime/core/session_advanced.h" ||
  rewind_fail "SessionAdvanced::WaitUntilDone no longer waits for the session's tasks"
TEM="$DIR/runtime/framework/resource_management/threaded_execution_manager.cc"
grep -qF 'it->second->active_tasks.empty() &&' "$TEM" &&
  grep -qF '!pending_callback_sessions_.contains(session_id));' "$TEM" ||
  rewind_fail "WaitUntilSessionDone no longer waits for the session's tasks and queued callbacks"
# The CPU/GPU executor moves its step back by any number of tokens (the NPU
# one does not, and is never asked to).
grep -qF 'absl::Status LlmLiteRtCompiledModelExecutorBase::SetCurrentStep(int new_step) {' \
  "$DIR/runtime/executor/llm_litert_compiled_model_executor.cc" ||
  rewind_fail "the compiled-model executor's SetCurrentStep moved"

# ── 17. SentencePiece: a NUL byte in a BPE piece ──
# SentencePiece 0.2.2 (the WORKSPACE pin since LiteRT-LM v0.17.0) refuses any
# vocabulary piece containing '\0' ("piece must not include null character").
# Byte-level BPE vocabularies converted to SP_Tokenizer without byte_fallback
# carry byte 0x00 as a NORMAL piece (Qwen3-0.6B.litertlm before HF e6687177,
# FastVLM-0.5B.litertlm: id 188), so engine_create fails on them, while
# LiteRT-LM's own pip wheel, which links Google's internal SentencePiece,
# loads and answers them (LiteRT-LM #3865). Upstream SentencePiece's own fix
# (867f4ae8, #1308) only covers models with byte_fallback.
# The check guards Darts, which throws on a NUL byte in a key. A BPE model
# builds no trie over its pieces (a hash map, InitializePieces(false)); only
# its USER_DEFINED pieces reach one (the prefix matcher). The patch keeps the
# refusal there and for every other model type (Unigram's trie holds all its
# pieces) and drops it for the rest of a BPE vocabulary.
# A Bazel `patches=` on the sentencepiece archive: Bazel applies it before
# the archive's patch_cmds (still under src/) and fails the fetch when the
# hunk no longer applies, which is what a SentencePiece bump has to produce.
# support/tokenizer:sentencepiece_nul_piece_test pins both halves.
SP_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
sp_fail() {
  echo "  ERROR: section 17: $1" >&2
  exit 1
}
SP_PATCH_CHOICE_FILE="$(mktemp)"
if ! grep -q "flutter_gemma_sentencepiece_nul_piece.patch" "$WORKSPACE_FILE"; then
  SP_PATCH_CHOICE="$SP_PATCH_CHOICE_FILE" python3 << 'PYEOF' || exit 1
import os
ws = os.environ['WORKSPACE_FILE']
content = open(ws).read()
anchor = '    name = "sentencepiece",\n'
if content.count(anchor) != 1:
    raise SystemExit("  ERROR: section 17: the sentencepiece http_archive is not in WORKSPACE")
start = content.index(anchor)
end = content.find('\n)', start)
block = content[start:end]
# The patch is a diff against this release; a moved pin needs a new one.
if 'strip_prefix = "sentencepiece-0.2.2"' not in block:
    raise SystemExit("  ERROR: section 17: sentencepiece is no longer 0.2.2 — "
                     "re-check the NUL-piece refusal and re-create the patch")
if 'patches' in block:
    # LiteRT-LM v0.19.0 carries its own (third_party/sentencepiece/
    # sentencepiece.patch): it accepts exactly the one-byte piece "\0" when it
    # is NORMAL in a BPE model without byte_fallback — enough for Qwen3-0.6B
    # and FastVLM-0.5B, not for Phi-4-mini-instruct, whose vocabulary also
    # holds the merge "\0\0" (id 156344; "piece must not include null
    # character" on our v0.19.0 build). Ours goes second, against the
    # upstream-patched file and in its -p0 form (patch_args apply to both).
    upstream = 'patches = ["@//third_party/sentencepiece:sentencepiece.patch"]'
    if block.count(upstream) != 1:
        raise SystemExit("  ERROR: section 17: the sentencepiece archive has "
                         "patches other than upstream's NUL-piece one")
    if 'patch_args' in block:
        raise SystemExit("  ERROR: section 17: the sentencepiece archive sets "
                         "patch_args; re-create the on-upstream patch for it")
    content = content.replace(
        upstream,
        'patches = ["@//third_party/sentencepiece:sentencepiece.patch", '
        '"//:flutter_gemma_sentencepiece_nul_piece.patch"]', 1)
    open(ws, 'w').write(content)
    open(os.environ['SP_PATCH_CHOICE'], 'w').write('on_upstream')
    print("  OK: sentencepiece archive applies upstream's patch, then "
          "patches/sentencepiece_nul_piece_on_upstream.patch")
    raise SystemExit(0)
open(os.environ['SP_PATCH_CHOICE'], 'w').write('plain')
content = content.replace(
    anchor,
    anchor +
    '    patches = ["//:flutter_gemma_sentencepiece_nul_piece.patch"],\n'
    '    patch_args = ["-p1"],\n', 1)
open(ws, 'w').write(content)
print("  OK: sentencepiece archive applies patches/sentencepiece_nul_piece.patch")
PYEOF
else
  echo "  SKIP: sentencepiece NUL-piece patch already in WORKSPACE"
fi
# Which file the WORKSPACE entry names: against upstream's patch (v0.19.0
# on) or against the bare 0.2.2 source. A WORKSPACE patched by an earlier run
# keeps its choice, read back from the entry.
sp_choice="$(cat "$SP_PATCH_CHOICE_FILE")"
rm -f "$SP_PATCH_CHOICE_FILE"
if [ -z "$sp_choice" ]; then
  if grep -q 'sentencepiece.patch", "//:flutter_gemma_sentencepiece_nul_piece.patch"' "$WORKSPACE_FILE"; then
    sp_choice=on_upstream
  else
    sp_choice=plain
  fi
fi
if [ "$sp_choice" = on_upstream ]; then
  cp "$SP_SRC_DIR/patches/sentencepiece_nul_piece_on_upstream.patch" \
    "$DIR/flutter_gemma_sentencepiece_nul_piece.patch"
else
  cp "$SP_SRC_DIR/patches/sentencepiece_nul_piece.patch" \
    "$DIR/flutter_gemma_sentencepiece_nul_piece.patch"
fi
cp "$SP_SRC_DIR/sentencepiece_nul_piece_test.cc" \
  "$DIR/support/tokenizer/sentencepiece_nul_piece_test.cc"
SP_TOKENIZER_BUILD="$DIR/support/tokenizer/BUILD"
grep -q 'name = "sentencepiece_tokenizer",' "$SP_TOKENIZER_BUILD" ||
  sp_fail "support/tokenizer:sentencepiece_tokenizer moved"
grep -qF 'CreateFromProto(' "$DIR/support/tokenizer/sentencepiece_tokenizer.h" ||
  sp_fail "SentencePieceTokenizer::CreateFromProto is gone"
if ! grep -q '"sentencepiece_nul_piece_test"' "$SP_TOKENIZER_BUILD"; then
  cat >> "$SP_TOKENIZER_BUILD" << 'BUILDEOF'

cc_test(
    name = "sentencepiece_nul_piece_test",
    srcs = ["sentencepiece_nul_piece_test.cc"],
    deps = [
        ":sentencepiece_tokenizer",
        "@com_google_absl//absl/status",
        "@com_google_absl//absl/strings:string_view",
        "@com_google_googletest//:gtest_main",
        "@sentencepiece//:sentencepiece_model_cc_proto",
    ],
)
BUILDEOF
fi
echo "  OK: section 17 test target in support/tokenizer"

# ── 18. Rewind bookkeeping (upstream PR #4197: LiteRT-LM #3947, #4195) ──
# 0.19.0's RollBackProcessedTokens turns the token before a rewind target into
# a pending token with no embedding, and on a model that takes embeddings
# (Gemma 4 E2B) the next prefill writes its id into the embedding input: one
# KV cell is wrong after every section 16 rewind (measured 2026-10-28,
# -1.152 vs -0.792). The same PR restores last_prefill_token_id on rewind
# (#4195). v0.20.0 fixes the embedding half itself (0101cf3b,
# LookupPendingTokenEmbeddings), so the patch keeps only the #4195 half: both
# execution managers' SetCurrentStep restore last_prefill_token_id. Drop it
# once the pin has that too (LiteRT-LM #4195, #4197 still open).
grep -qF 'LookupPendingTokenEmbeddings(' "$DIR/runtime/executor/llm_litert_compiled_model_executor.cc" || {
  echo "  ERROR: section 18: upstream's pending-token embedding lookup (0101cf3b) is gone" >&2
  exit 1
}
REWIND4197_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/rewind_bookkeeping_4197.patch"
if git -C "$DIR" apply --check "$REWIND4197_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$REWIND4197_PATCH"
  echo "  OK: rewind restores the last prefill token (#4195)"
elif git -C "$DIR" apply --reverse --check "$REWIND4197_PATCH" 2>/dev/null; then
  echo "  SKIP: rewind bookkeeping (#4197) already applied"
else
  echo "  ERROR: $REWIND4197_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

# ── 19. Android: the statically linked GPU accelerator is OpenCL only ──
# libLiteRtLm links runtime/executor:default_static_gpu_accelerator on Apple
# and Android. Up to v0.19.1 Android's was LiteRT's combined ML Drift
# accelerator (its WebGPU delegate made libLiteRtLm NEED libwebgpu_dawn.so).
# v0.20.0 (6cf79561) uses ml_drift_cl_gl_accelerator, as Google's own
# litertlm-android does: when OpenCL does not load it switches to OpenGL with
# one INFO log line and still reports "LiteRT GPU", and nothing tells the app
# which API runs (OpenGL is "Experimental, do not use" in LiteRT). That is a
# silent backend change, so Android stays on ml_drift_cl_accelerator ("GPU
# OpenCL"), the accelerator every Android build carried so far: without
# OpenCL the GPU load fails and says so (0.20 migration decision D2; an
# explicit OpenGL backend is research for later). build_android.sh checks the
# built library carries "GPU OpenCL" and not "Using OpenGL instead".
ANDROID_CL_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/android_static_gpu_opencl.patch"
grep -q 'name = "default_static_gpu_accelerator"' "$DIR/runtime/executor/BUILD" || {
  echo "  ERROR: section 19: runtime/executor:default_static_gpu_accelerator is gone" >&2
  exit 1
}
if git -C "$DIR" apply --check "$ANDROID_CL_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$ANDROID_CL_PATCH"
  echo "  OK: section 19: Android links the OpenCL-only GPU accelerator"
elif git -C "$DIR" apply --reverse --check "$ANDROID_CL_PATCH" 2>/dev/null; then
  echo "  SKIP: Android OpenCL-only accelerator already applied"
else
  echo "  ERROR: $ANDROID_CL_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

# ── 20. Linux and Windows: no fused GPU sampler ──
# From v0.19.0 the TopK GPU samplers are compiled from ML Drift source and
# runtime/components:default_static_gpu_samplers links the WebGPU one into
# libLiteRtLm on every non-Apple, non-Android target, including the
# dynamic-link mode Linux and Windows use (litert_runtime_link_mode=dynamic).
# Against Google's prebuilt libLiteRtWebGpuAccelerator our libstdc++/MSVC
# build of the sampler crashed the first GPU decode: SIGSEGV in
# TopKWebGpuSampler::SampleToIdAndScoreBuffer on a T4, 0xC0000409 in
# LiteRtLm.dll on Arc B390 and Arc 140V. This leaves the sampler out in
# dynamic-link mode; the sampler factory samples on the CPU and the logits
# stay on the GPU. From v0.20.0 the accelerator is built from source with the
# same toolchain (upstream 769af92e), so the crash's premise may be gone; the
# section stays until a Linux and a Windows GPU decode run without it.
DESKTOP_SAMPLER_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/desktop_no_static_gpu_sampler.patch"
if grep -q 'name = "default_static_gpu_samplers"' "$DIR/runtime/components/BUILD"; then
  if git -C "$DIR" apply --check "$DESKTOP_SAMPLER_PATCH" 2>/dev/null; then
    git -C "$DIR" apply "$DESKTOP_SAMPLER_PATCH"
    echo "  OK: no fused GPU sampler in dynamic-link builds (Linux, Windows)"
  elif git -C "$DIR" apply --reverse --check "$DESKTOP_SAMPLER_PATCH" 2>/dev/null; then
    echo "  SKIP: no fused GPU sampler already applied"
  else
    echo "  ERROR: $DESKTOP_SAMPLER_PATCH does not apply to this LiteRT-LM revision" >&2
    exit 1
  fi
fi

# ── 21. XNNPACK: no pf32 SME2 GEMM / x32 SME2 LHS packing on Apple ──
# On SME2 CPUs (Apple M4/M5) XNNPACK's KleidiAI pf32 SME2 f32 GEMM gives
# thread-count-dependent results: up to 2.5 nat per token between sessions at
# 4 threads, a repeated wrong answer at other counts, 1 thread off on some
# models (google/XNNPACK#11789; doc/research/macos-cpu-nondeterminism-0.19.md
# on research/macos-cpu-nondeterminism-0.19). patches/
# xnnpack_pf32_sme2_apple.patch skips only those three SME2 branches when
# XNN_PLATFORM_MAC or XNN_PLATFORM_IOS; elsewhere it compiles to the same code.
# TensorFlow defines the XNNPACK repository this build uses (it comes before
# LiteRT's, which Bazel then skips), so the hook is a second patch on the
# org_tensorflow archive that adds our file to that tf_http_archive's
# patch_file. Both apply at fetch time without fuzz: a TensorFlow that moves
# the XNNPACK pin, or an XNNPACK whose config lines moved, fails the build
# until the patch is re-checked. Drop both when #11789 is fixed.
XNN_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! grep -q "flutter_gemma_tensorflow_xnnpack_patch_file.patch" "$WORKSPACE_FILE"; then
  python3 << 'PYEOF' || exit 1
import os
ws = os.environ['WORKSPACE_FILE']
content = open(ws).read()
anchor = '    name = "org_tensorflow",\n'
if content.count(anchor) != 1:
    raise SystemExit("  ERROR: section 21: the org_tensorflow http_archive is not in WORKSPACE")
start = content.index(anchor)
end = content.find('\n)', start)
block = content[start:end]
upstream = 'patches = ["@//third_party/tensorflow:tensorflow.patch"]'
if block.count(upstream) != 1:
    raise SystemExit("  ERROR: section 21: org_tensorflow's patches are not upstream's one "
                     "tensorflow.patch; re-check how the XNNPACK patch is hooked in")
if 'patch_args' in block:
    raise SystemExit("  ERROR: section 21: org_tensorflow sets patch_args; the TensorFlow "
                     "patch is written for the default -p0")
new_block = block.replace(
    upstream,
    'patches = ["@//third_party/tensorflow:tensorflow.patch", '
    '"//:flutter_gemma_tensorflow_xnnpack_patch_file.patch"]', 1)
open(ws, 'w').write(content[:start] + new_block + content[end:])
print("  OK: org_tensorflow applies patches/tensorflow_xnnpack_patch_file.patch "
      "(XNNPACK gets patches/xnnpack_pf32_sme2_apple.patch)")
PYEOF
else
  echo "  SKIP: XNNPACK SME2 patch already hooked into org_tensorflow"
fi
cp "$XNN_SRC_DIR/patches/tensorflow_xnnpack_patch_file.patch" \
  "$DIR/flutter_gemma_tensorflow_xnnpack_patch_file.patch"
cp "$XNN_SRC_DIR/patches/xnnpack_pf32_sme2_apple.patch" \
  "$DIR/flutter_gemma_xnnpack_pf32_sme2_apple.patch"

# ── 32. TensorFlow patch_cmds run BAZEL_SH's bash (Windows) ──
# TensorFlow's tf_http_archive (third_party/repo.bzl, and XLA's copy) runs
# patch_cmds as ctx.execute(["bash", "-c", cmd]). On Windows CreateProcess
# searches System32 before PATH, so a GitHub runner starts the WSL launcher,
# which has no distribution, and the fetch of build_bazel_rules_android fails
# with an empty stderr; a machine without that launcher (the Panther Lake box)
# never sees it. From v0.20.0 libLiteRt and the WebGPU accelerator build from
# LiteRT's source, which fetches it. patches/tensorflow_repo_bazel_sh.patch
# runs BAZEL_SH when it is set (the Windows workflows set Git's bash) and plain
# bash otherwise, so Linux and macOS are unchanged. Hooked in after section
# 21's patch, the same way.
TF_SH_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! grep -q "flutter_gemma_tensorflow_repo_bazel_sh.patch" "$WORKSPACE_FILE"; then
  python3 << 'PYEOF' || exit 1
import os
ws = os.environ['WORKSPACE_FILE']
content = open(ws).read()
anchor = '    name = "org_tensorflow",\n'
start = content.index(anchor)
end = content.find('\n)', start)
block = content[start:end]
after21 = ('patches = ["@//third_party/tensorflow:tensorflow.patch", '
           '"//:flutter_gemma_tensorflow_xnnpack_patch_file.patch"]')
if block.count(after21) != 1:
    raise SystemExit("  ERROR: section 32: org_tensorflow's patches are not upstream's "
                     "tensorflow.patch plus section 21's; re-check the hook")
new_block = block.replace(
    after21,
    after21[:-1] + ', "//:flutter_gemma_tensorflow_repo_bazel_sh.patch"]', 1)
open(ws, 'w').write(content[:start] + new_block + content[end:])
print("  OK: section 32: TensorFlow patch_cmds run BAZEL_SH (patches/tensorflow_repo_bazel_sh.patch)")
PYEOF
else
  echo "  SKIP: section 32 already hooked into org_tensorflow"
fi
cp "$TF_SH_SRC_DIR/patches/tensorflow_repo_bazel_sh.patch" \
  "$DIR/flutter_gemma_tensorflow_repo_bazel_sh.patch"

# ── 22. NPU executor: save every KV cache buffer of a conversation ──
# The NPU executor's CloneContext saved only the KV buffers its prefill
# signature takes, so a layer only decode reads kept the previous
# conversation's values (Gemma 4 E2B on the Qualcomm SM8750 bundle, DDP Galaxy
# S25 Ultra 2026-11-02, N1). Our patch is gone: upstream 9738e180 (in v0.20.0,
# LiteRT-LM #4355) saves every buffer of the active context group. Anchor only.
grep -q 'ActiveContextGroup().input_kv_cache_buffers' \
    "$DIR/runtime/executor/llm_litert_npu_compiled_model_executor.cc" || {
  echo "  ERROR: section 22: NPU CloneContext no longer saves the active group's" \
    "input_kv_cache_buffers (upstream 9738e180)" >&2
  exit 1
}
echo "  OK: section 22: NPU CloneContext saves every KV cache buffer (upstream 9738e180)"

# ── 23. How a turn ended: the turn-end record ──
# A streamed reply ends with the same final chunk whether the model ended it
# (stop token), it reached max_output_tokens (Tasks::Decode returns kDone for
# both), or its decode filled the context window (kMaxNumTokensReached, a
# normal completion while return_error_on_max_tokens_reached is off, which no C
# setter reaches). An input that does not fit ends with RESOURCE_EXHAUSTED (or,
# longer than the whole window, INVALID_ARGUMENT) and leaves the session failed:
# its failed prefill stays a dependency of every later task (measured on
# v0.19.0, macOS CPU and Metal). Section 16 read it as "failed, delete".
# Decode now marks a stop by max_output_tokens on its kDone Responses (a field,
# not a new TaskState, so every kDone consumer is unchanged); the conversation
# records how its last decode ended before the callback that reports it; the C
# wrapper turns that and the status into the LiteRtLmTurnEnd it keeps per send
# (section 16), with the absl code, behind
# litert_lm_conversation_get_last_turn_end. The over-long input is reported as
# RESOURCE_EXHAUSTED too, and rewind_cancelled_turn rewinds a conversation
# whose input did not fit to that turn's checkpoint, which makes it usable;
# after a turn that hit max_output_tokens or the window in its decode it
# changes nothing. A CPU/GPU executor refuses a prefill when every prefill
# signature is longer than the positions left (Gemma 4 E2B: 125 left, CPU and
# Metal; FunctionGemma 270M on Metal: 249), however short the input, which
# tasks.cc's own check lets through; upstream says FAILED_PRECONDITION, so the
# window reads as an error. Both such refusals in
# GetOptimizedPrefillWorkGroups say RESOURCE_EXHAUSTED: the turn ends
# context_full and is rewound like the others. Only these window checks (the
# two in tasks.cc, the two in GetOptimizedPrefillWorkGroups, and the
# conversation's own error for a prefill into a window a decode filled) mark
# their RESOURCE_EXHAUSTED with the payload kContextWindowFullPayload; a
# RESOURCE_EXHAUSTED without it (a failed allocation) ends the turn failed and
# is not rewound, and the C wrapper strips the payload from the error text the
# caller sees (probe commands turnend and exhausted, the latter on a build with
# a probe-only fault hook; mutations of each marking caught, 2026-11-04). A
# prefill or decode that fails
# after its benchmark turn started never ended that turn, so every later turn
# of the session failed with "Prefill turn prefill:N already started" (the
# Dart client always enables benchmark); tasks.cc forgets an unended turn's
# start on every exit. A send refused before it starts (a NULL argument, a
# message that is not JSON) is reported as kLiteRtLmTurnEndRefused with its
# status code instead of the end of the send before it; rewind_cancelled_turn
# still decides by the last send that started. Needs sections 16 and 18.
TURN_END_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/conversation_turn_end_record.patch"
if git -C "$DIR" apply --check "$TURN_END_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$TURN_END_PATCH"
  echo "  OK: conversations record how each turn ended"
elif git -C "$DIR" apply --reverse --check "$TURN_END_PATCH" 2>/dev/null; then
  echo "  SKIP: turn-end record already applied"
else
  echo "  ERROR: $TURN_END_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

# ── 24. A prefill that reuses the KV positions a rewind left keeps its step ──
# After a rewind, a prefill whose input fully matched the processed tokens ran
# from the checkpoint's step and lost the matched tokens (Gemma 4 E2B, macOS CPU
# and Metal, 2026-11-04, probe convrewind). Our patch is gone: upstream
# e0dcad4e (in v0.20.0) calls SetCurrentStep(current_step) on that branch.
# Anchor only.
grep -q 'ABSL_RETURN_IF_ERROR(llm_executor_->SetCurrentStep(current_step));' \
    "$DIR/runtime/framework/resource_management/resource_manager.cc" || {
  echo "  ERROR: section 24: the full-match prefill no longer sets the executor's" \
    "step (upstream e0dcad4e)" >&2
  exit 1
}
echo "  OK: section 24: a prefill after a rewind keeps the matched step (upstream e0dcad4e)"

# ── 25. A new context starts a hybrid model's linear attention state at zero ──
# LFM2 keeps a convolution state (kv_cache_c_) beside its attention KV cache.
# Reset() and a new session only move the step to 0: enough for a KV cache,
# which is masked by position, but the convolution state of the previous
# conversation stayed, so every conversation after the first on one engine
# answered differently (LFM2.5-230M int8, macOS CPU and Metal, 2026-11-04,
# probe command xsession; a fresh engine always gave the first answer). The
# state was only cleared when its buffers were created. A prefill into an
# empty context (step 0, no processed tokens) now clears the buffers of type
# TYPE_LINEAR_ATTENTION in both states; attention-only models have none.
LINEAR_STATE_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/linear_attention_state_clear.patch"
if git -C "$DIR" apply --check "$LINEAR_STATE_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$LINEAR_STATE_PATCH"
  echo "  OK: a new context clears the linear attention state"
elif git -C "$DIR" apply --reverse --check "$LINEAR_STATE_PATCH" 2>/dev/null; then
  echo "  SKIP: linear attention state clear already applied"
else
  echo "  ERROR: $LINEAR_STATE_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

# ── 26. The thinking constraint copies a user bitmap without its end() ──
# With thinking on, Tasks::Decode wraps the user constraint (the tool
# constraint, whenever a session has tools) in ThinkingBudgetConstraint. On
# the first decode step of a turn its ComputeMask copies the user mask's
# words(), begin() to end(), to add the start-of-thought token. Up to
# native-v0.19.1 that mask came from Google's prebuilt
# libGemmaModelConstraintProvider, whose vector is libc++'s {begin, size,
# capacity} (std::__u), while LiteRtLm.dll is MSVC STL ({first, last, end}):
# on Windows the element count was read as the end pointer, the copy threw
# std::length_error, and the process aborted (0xc0000409, fast-fail 7) on the
# first token of every thinking turn with tools (Intel's Gemma 4 12B on the
# Panther Lake NPU, 2026-11-12). The copy takes (vocab_size + 63) / 64 words
# from words().data() instead: the begin pointer and vocab_size sit at the
# same offsets in both layouts, and they are all CompositeLogitMask and the
# mask runner read. From native-v0.20.0-a the tool constraint is LLGuidance's
# (section 29), built into this runtime with its own standard library, so no
# mask crosses a standard-library boundary any more; the copy stays because it
# is right for any BitmapLogitMask, and its test (a user bitmap holding more
# words than its vocabulary needs) runs in the Linux CI build. Applied on
# every target to keep one source tree.
THINKING_MASK_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/thinking_budget_user_bitmap_words.patch"
if git -C "$DIR" apply --check "$THINKING_MASK_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$THINKING_MASK_PATCH"
  echo "  OK: the thinking constraint copies a user bitmap by data() and vocab size"
elif git -C "$DIR" apply --reverse --check "$THINKING_MASK_PATCH" 2>/dev/null; then
  echo "  SKIP: thinking constraint user-bitmap fix already applied"
else
  echo "  ERROR: $THINKING_MASK_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi
if grep -q 'words().end()' \
    "$DIR/runtime/components/constrained_decoding/thinking_budget_constraint.cc"; then
  echo "  ERROR: section 26: thinking_budget_constraint.cc still reads a user mask's words().end()" >&2
  exit 1
fi

# ── 27. A multi-signature NPU KV cache in an OpenVINO buffer is aliased ──
# Intel's GlobalGraph-v3 bundles (gemma4-12B-it-Intel_PTL_NPU.litertlm) keep
# KV caches of several lengths in OpenVINO tensor buffers, which
# CreateAliasBuffer could not alias ("Unsupported tensor buffer type for
# cross-platform aliasing: 100"). Our backport is gone: upstream 3db1cfd0ab is
# in v0.20.0. Anchor only.
if ! grep -q 'IsUserCustomBuffer' \
    "$DIR/runtime/executor/npu/llm_litert_npu_compiled_model_executor_utils.cc"; then
  echo "  ERROR: section 27: CreateAliasBuffer has no custom-buffer branch" >&2
  exit 1
fi
echo "  OK: section 27: NPU KV caches in custom tensor buffers are aliased (upstream 3db1cfd0ab)"

# ── 28. Apple: Metal argument buffers on, as up to v0.19.1 ──
# v0.20.0 (upstream 08ec69e6) turns Metal argument buffers off in
# SetCommonGpuOptions for speed. Without them every buffer a kernel binds is a
# [[buffer(n)]] slot, and Apple GPUs have 31 (0-30): Gemma 4 E2B on Metal then
# failed engine_create with "'buffer' attribute parameter is out of bounds:
# must be between 0 and 30" (a kernel binding buffer(31) and buffer(32); FP32
# at 4096 tokens and FP16 at 2048, our v0.20.0 build on an M5 Pro,
# 2026-11-25). With them on, as every release up to v0.19.1 ran, the same
# build answers text, image, audio, tools, thinking and a stopped turn at
# ~120 tok/s. Drop this section once upstream's kernels fit the slot limit.
GPU_UTILS="$DIR/runtime/executor/litert_compiled_model_executor_utils.cc"
if grep -q 'gpu_options.SetUseMetalArgumentBuffers(false);' "$GPU_UTILS"; then
  sed -i.bak 's/gpu_options\.SetUseMetalArgumentBuffers(false);/gpu_options.SetUseMetalArgumentBuffers(true);  \/\/ flutter_edge_ai section 28/' "$GPU_UTILS"
  rm -f "$GPU_UTILS.bak"
fi
[ "$(grep -c 'SetUseMetalArgumentBuffers(true);  // flutter_edge_ai section 28' "$GPU_UTILS")" = 1 ] &&
  ! grep -q 'SetUseMetalArgumentBuffers(false)' "$GPU_UTILS" || {
  echo "  ERROR: section 28: SetCommonGpuOptions' Metal argument-buffer line moved" >&2
  exit 1
}
echo "  OK: section 28: Metal argument buffers on (Apple)"

# ── 29. Tool-call constraints from LLGuidance, not the prebuilt FST provider ──
# LiteRT-LM builds the Gemma 3, Gemma 4 and FunctionGemma tool-call
# constraints with Google's prebuilt libGemmaModelConstraintProvider (FST) by
# default. Its constraints know only "call a tool or not": every tool_choice
# but auto (none, required, a forced function, allowed tools; C API 1.1)
# fails the send with FailedPrecondition. With enable_fst_constraints=false the
# processors build them with LLGuidance, compiled from source here, which
# implements every tool_choice (0.20 migration decision D8). The flag goes into
# the tree's .bazelrc so every build of it gets it: the scripts here and both
# CI workflows. Upstream keeps FST the default pending its own validation
# (b/574011343); ours is the tool-call accuracy matrix of the migration.
grep -q 'name = "enable_fst_constraints"' "$DIR/build_config/BUILD" &&
  grep -q 'litert_lm_fst_constraints_disabled' "$DIR/runtime/conversation/model_data_processor/BUILD" || {
  echo "  ERROR: section 29: build_config:enable_fst_constraints is gone" >&2
  exit 1
}
if ! grep -q 'flutter_edge_ai section 29' "$DIR/.bazelrc"; then
  printf '\n# flutter_edge_ai section 29: tool-call constraints from LLGuidance\nbuild --//build_config:enable_fst_constraints=false\n' >> "$DIR/.bazelrc"
fi
echo "  OK: section 29: tool-call constraints from LLGuidance (enable_fst_constraints=false)"

# ── 30. Windows: no preprocessor directive inside a C API macro's arguments ──
# c/engine.cc (v0.20.0) has an #if/#else/#endif inside the arguments of
# LITERT_LM_C_ASSIGN_OR_RETURN, which MSVC's traditional preprocessor rejects
# (C2143/C1019): //c:libLiteRtLm.dylib does not build on Windows. Upstream's
# Windows CI never compiles c/engine.cc. patches/c_engine_msvc_macro_directive.patch
# hoists the directive into a local; drop it once upstream does the same.
MSVC_MACRO_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/c_engine_msvc_macro_directive.patch"
if git -C "$DIR" apply --check "$MSVC_MACRO_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$MSVC_MACRO_PATCH"
  echo "  OK: section 30: c/engine.cc builds with MSVC (no directive in macro arguments)"
elif git -C "$DIR" apply --reverse --check "$MSVC_MACRO_PATCH" 2>/dev/null; then
  echo "  SKIP: section 30 already applied"
elif ! grep -q '_get_osfhandle(fd))))));' "$DIR/c/engine.cc"; then
  echo "  OK: section 30: upstream no longer has the directive inside the macro; drop the section"
else
  echo "  ERROR: $MSVC_MACRO_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

# ── 31. FunctionGemma: tool-call arguments in the declared order (LLGuidance) ──
# With section 29 the tool-call grammar is LLGuidance's, which (upstream
# 9235f915) puts a tool call's arguments in alphabetical order, as Gemma 4's
# template renders them. FunctionGemma's templates render them in the order
# the tool declares them, and FunctionGemma 270M writes that order: forced into
# alphabetical order it chose worse argument values than under the FST provider
# (the D8 tool-call matrix, macOS CPU and Metal, 2026-11-25).
# patches/llg_fc_declared_argument_order.patch adds a declared-order mode to the
# FC grammar and turns it on for FunctionGemma only.
LLG_ORDER_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/llg_fc_declared_argument_order.patch"
if git -C "$DIR" apply --check "$LLG_ORDER_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$LLG_ORDER_PATCH"
  echo "  OK: section 31: FunctionGemma's tool-call arguments in the declared order"
elif git -C "$DIR" apply --reverse --check "$LLG_ORDER_PATCH" 2>/dev/null; then
  echo "  SKIP: section 31 already applied"
else
  echo "  ERROR: $LLG_ORDER_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

# ── 33. Text LoRA sessions (upstream 4d4fd6e5 + backport of LiteRT-LM PR #2508) ──
# The public source (v0.20.0 and main) refuses every text LoRA: ResourceManager
# returns "Lora is not supported." where its audio branch loads the adapter,
# and the LLM executor cannot load or bind one. Google's binaries can; upstream
# 4d4fd6e5 says the block that binds an active adapter is stripped from OSS
# builds. Part 1 is 4d4fd6e5 itself (main, after the v0.20.0 fork): zero LoRA
# buffers and a populated lora_param_tensor when no adapter is active (GPU
# output corruption on OpenCL and Metal otherwise). Part 2,
# patches/text_lora_sessions.patch, is LiteRT-LM PR #2508 (open upstream)
# rebased onto it, with the active adapter bound where the stripped block was;
# its header says what is ours. Drop part 1 at the first pin containing
# 4d4fd6e5, part 2 once upstream loads text LoRA itself. Comes last: it patches
# c/engine.cc and the executor after sections 1-31.
LORA_DIR="$(cd "$(dirname "$0")" && pwd)/patches"
for LORA_PATCH in "$LORA_DIR/litert_lm_zero_lora_buffers_4d4fd6e5.patch" \
    "$LORA_DIR/text_lora_sessions.patch"; do
  # The build scripts reuse a tree and reset it with `git checkout -f`, which
  # leaves the untracked files an earlier run's patch created (part 1 adds two
  # testdata files), and `git apply --check` then fails on "already exists".
  # When the patch is not applied, an untracked file it creates is such a
  # leftover: remove it so the patch can create it again.
  if ! git -C "$DIR" apply --reverse --check "$LORA_PATCH" 2>/dev/null; then
    for created in $(git -C "$DIR" apply --summary "$LORA_PATCH" | awk '$1 == "create" {print $4}'); do
      if [ -e "$DIR/$created" ] && ! git -C "$DIR" ls-files --error-unmatch "$created" >/dev/null 2>&1; then
        rm -f "$DIR/$created"
        echo "  section 33: removed $created left by an earlier run"
      fi
    done
  fi
  if git -C "$DIR" apply --check "$LORA_PATCH" 2>/dev/null; then
    git -C "$DIR" apply "$LORA_PATCH"
    echo "  OK: section 33: applied $(basename "$LORA_PATCH")"
  elif git -C "$DIR" apply --reverse --check "$LORA_PATCH" 2>/dev/null; then
    echo "  SKIP: section 33: $(basename "$LORA_PATCH") already applied"
  else
    echo "  ERROR: $LORA_PATCH does not apply to this LiteRT-LM revision" >&2
    exit 1
  fi
done
grep -q 'bound_active_lora = true;' "$DIR/runtime/executor/llm_litert_compiled_model_executor.cc" ||
  { echo "  ERROR: section 33: the active LoRA is not bound in RunSignature" >&2; exit 1; }

echo "Patch complete."
