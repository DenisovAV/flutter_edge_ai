#!/bin/bash
# Patch LiteRT-LM C API source to add:
# 1. cc_binary(linkshared=True) target for shared library (Linux dynamic-list
#    + Windows .def whitelist for the symbols our Dart FFI bindings call)
# 2. set_use_hw_masking_for_npu setter (Intel LunarLake/PantherLake NPU)
# 3. GPU smooth-UI knobs — gpu_context_low_priority + kernel_batch_size (#364)
# 4. gpu_registry.cc dlopen rewrite for App-Store-safe framework paths (Apple)
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
# Requires building with --define=litert_runtime_link_mode=dynamic (plus
# --define=resolve_symbols_in_exec=false) so that libLiteRtLm references
# libLiteRt dynamically at runtime instead of statically linking the LiteRt
# C API, which would put two copies of the runtime in the process alongside
# the prebuilt accelerator.
#
# NOT litert_link_capi_so=true. Upstream deleted that name; no config_setting
# reads it, and Bazel accepts unknown --defines silently, so passing it links
# statically while looking correct. That is what broke Windows GPU from
# v0.14.0 (when Dawn was split into its own library) through v0.16.0 — and was
# misreported upstream as LiteRT-LM #2957 before the cause turned out to be
# ours. Both live names are documented in upstream's
# docs/getting-started/build-and-run.md as required for GPU.
if ! grep -q '"libLiteRtLm.dylib"' "$DIR/c/BUILD"; then
  # Dynamic-list: make these symbols visible in the dynamic export table.
  cat > "$DIR/c/dynamic_list.lds" << 'LDSEOF'
{
  LiteRt*;
  litert_lm_*;
};
LDSEOF

  # Windows .def: whitelist of symbols to export from LiteRtLm.dll.
  # Derived from lib/core/ffi/litert_lm_bindings.dart lookupFunction calls.
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
  litert_lm_conversation_send_message
  litert_lm_conversation_send_message_stream
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
  litert_lm_engine_settings_set_use_hw_masking_for_npu
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

# ── 4b. Add set_use_hw_masking_for_npu for Intel LunarLake/PantherLake ──
# Default NpuConfig.use_hw_masking_for_npu=true makes LiteRT setup HW mask
# update path (MaskUpdateMethod::kWH) which Intel preview NPU silicon
# doesn't fully support → engine_create crash (CFG / 0xc0000409). Per Matt
# Kreileder's Intel NPU pipeline instructions, must call with `false` for
# LunarLake / PantherLake. Upstream C API doesn't expose this — patch in
# our own setter that writes through NpuConfig variant on main executor.
if ! grep -q "set_use_hw_masking_for_npu" "$DIR/c/engine.h"; then
  sed -i.bak '/Creates a LiteRT LM Engine from the given settings/i\
// Sets whether to use hardware masking for NPU. Default is true which on\
// Intel LunarLake/PantherLake preview silicon causes engine_create to\
// crash because the NPU HW mask update path is not fully supported.\
// Pass false to force CPU/SIMD mask update fallback.\
LITERT_LM_C_API_EXPORT\
void litert_lm_engine_settings_set_use_hw_masking_for_npu(\
    LiteRtLmEngineSettings* settings, bool value);\
' "$DIR/c/engine.h"
  rm -f "$DIR/c/engine.h.bak"
  echo "  OK: Added set_use_hw_masking_for_npu to c/engine.h"
else
  echo "  SKIP: c/engine.h already has set_use_hw_masking_for_npu"
fi

if ! grep -q "set_use_hw_masking_for_npu" "$DIR/c/engine.cc"; then
  sed -i.bak '/void litert_lm_engine_settings_set_activation_data_type/i\
void litert_lm_engine_settings_set_use_hw_masking_for_npu(\
    LiteRtLmEngineSettings* settings, bool value) {\
  if (settings \&\& settings->settings) {\
    auto\& exec = settings->settings->GetMutableMainExecutorSettings();\
    litert::lm::NpuConfig config;\
    auto current = exec.GetBackendConfig<litert::lm::NpuConfig>();\
    if (current.ok()) {\
      config = *current;\
    }\
    config.use_hw_masking_for_npu = value;\
    exec.SetBackendConfig(config);\
  }\
}\
' "$DIR/c/engine.cc"
  rm -f "$DIR/c/engine.cc.bak"
  echo "  OK: Added set_use_hw_masking_for_npu impl to c/engine.cc"
else
  echo "  SKIP: c/engine.cc already has set_use_hw_masking_for_npu"
fi

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
void litert_lm_engine_settings_set_gpu_context_low_priority(\
    LiteRtLmEngineSettings* settings, bool value);\
\
// Hints a GPU kernel batch size so the delegate periodically flushes, giving\
// the UI compositor scheduling windows during long GPU work (#364).\
LITERT_LM_C_API_EXPORT\
void litert_lm_engine_settings_set_kernel_batch_size(\
    LiteRtLmEngineSettings* settings, int kernel_batch_size);\
' "$DIR/c/engine.h"
  rm -f "$DIR/c/engine.h.bak"
  echo "  OK: Added GPU smooth-UI knob setters to c/engine.h"
else
  echo "  SKIP: c/engine.h already has set_gpu_context_low_priority"
fi

if ! grep -q "set_gpu_context_low_priority" "$DIR/c/engine.cc"; then
  sed -i.bak '/void litert_lm_engine_settings_set_activation_data_type/i\
void litert_lm_engine_settings_set_gpu_context_low_priority(\
    LiteRtLmEngineSettings* settings, bool value) {\
  if (settings \&\& settings->settings) {\
    auto\& main_settings = settings->settings->GetMutableMainExecutorSettings();\
    auto advanced_settings = main_settings.GetAdvancedSettings().value_or(\
        litert::lm::AdvancedSettings());\
    advanced_settings.gpu_context_low_priority = value;\
    main_settings.SetAdvancedSettings(advanced_settings);\
  }\
}\
\
void litert_lm_engine_settings_set_kernel_batch_size(\
    LiteRtLmEngineSettings* settings, int kernel_batch_size) {\
  if (settings \&\& settings->settings) {\
    auto\& main_settings = settings->settings->GetMutableMainExecutorSettings();\
    auto advanced_settings = main_settings.GetAdvancedSettings().value_or(\
        litert::lm::AdvancedSettings());\
    advanced_settings.hint_kernel_batch_size = kernel_batch_size;\
    main_settings.SetAdvancedSettings(advanced_settings);\
  }\
}\
' "$DIR/c/engine.cc"
  rm -f "$DIR/c/engine.cc.bak"
  echo "  OK: Added GPU smooth-UI knob impls to c/engine.cc"
else
  echo "  SKIP: c/engine.cc already has set_gpu_context_low_priority"
fi

# ── 10. Patch sampler_factory.cc + WORKSPACE for App-Store-safe dlopen on Apple ──
#
# `gpu_registry.cc` (LiteRT) and `sampler_factory.cc` (LiteRT-LM) hardcode the
# dylib basename "libLiteRtMetalAccelerator.dylib" / "libLiteRtTopKMetalSampler.dylib"
# in their dlopen calls. Native Assets bundles each prebuilt dylib as
# `<X>.framework/<X>` (Apple's required structure for iOS) — there is no flat
# `lib<X>.dylib` file in the app bundle for dyld to find by basename.
#
# Older flutter_gemma versions worked around this by symlinking lib*.dylib
# alongside the frameworks in `Frameworks/`, but Apple App Store Connect
# rejects that with ITMS-90432 ("Unexpected file found in Frameworks").
#
# Proper fix: rewrite the dlopen path on Apple to a relative-to-executable
# framework path, which dyld resolves natively:
#   `@executable_path/../Frameworks/<X>.framework/<X>` on macOS
#   `@executable_path/Frameworks/<X>.framework/<X>` on iOS
#
# Verified empirically (2026-04-30) on a built macOS Runner.app: the
# @executable_path-relative form resolves both from a binary in Contents/MacOS
# and from a binary inside another framework's Versions/A — i.e. it works for
# gpu_registry's call site inside libLiteRtLm.dylib.

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

# 10b. gpu_registry.cc lives in LiteRT (transitive dep). Bazel applies
# patch_cmds AFTER extracting an http_archive — that's the canonical hook for
# patching transitive deps. Use python with a separator to avoid the multi-
# layer shell-inside-Bazel-string-inside-python quoting nightmare.
export WORKSPACE_FILE="$DIR/WORKSPACE"
if [ -f "$WORKSPACE_FILE" ] && ! grep -q "FLUTTER_GEMMA_GPU_REGISTRY_PATCH" "$WORKSPACE_FILE"; then
  python3 << 'PYEOF'
import os
ws = os.environ['WORKSPACE_FILE']
with open(ws, 'r') as f:
    content = f.read()

# The existing third_party-rewrite line is the anchor. Use a stable substring
# match (the file path is unique enough).
anchor_substring = 'third_party/*/*",'
new_line_after_anchor = """
        # FLUTTER_GEMMA_GPU_REGISTRY_PATCH — App Store ITMS-90432 fix:
        # rewrite gpu_registry.cc dlopen path on Apple to a framework path so
        # dyld resolves the bundled .framework/<X> via @executable_path. iOS
        # bundle is flat (Frameworks/), macOS bundle has Contents/Frameworks/.
        "sed -i.bak 's|\\"libLiteRtMetalAccelerator\\" SO_EXT|FLUTTER_GEMMA_METAL_FW_PATH|g' litert/runtime/accelerators/gpu_registry.cc",
        # Inject the macro definition AFTER the namespace opens (i.e. after
        # the SO_EXT block has fully closed, since SO_EXT is defined before
        # the namespace block). The TargetConditionals.h include must be
        # wrapped in #if defined(__APPLE__) — that header is Apple-only,
        # Android NDK doesn't ship it. Using awk to avoid sed nesting issues.
        "awk 'BEGIN{p=0} /^namespace litert::internal/ && !p {print; print \\"\\"; print \\"#if defined(__APPLE__)\\"; print \\"#include <TargetConditionals.h>\\"; print \\"#if TARGET_OS_OSX\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"@executable_path/../Frameworks/LiteRtMetalAccelerator.framework/LiteRtMetalAccelerator\\\\\\"\\"; print \\"#elif TARGET_OS_IPHONE\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"@executable_path/Frameworks/LiteRtMetalAccelerator.framework/LiteRtMetalAccelerator\\\\\\"\\"; print \\"#else\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"libLiteRtMetalAccelerator.dylib\\\\\\"\\"; print \\"#endif\\"; print \\"#else\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"libLiteRtMetalAccelerator\\\\\\" SO_EXT\\"; print \\"#endif\\"; p=1; next} {print}' litert/runtime/accelerators/gpu_registry.cc > /tmp/gpu_registry.cc.new && mv /tmp/gpu_registry.cc.new litert/runtime/accelerators/gpu_registry.cc","""

# Find the anchor line and insert our new lines right after it.
idx = content.find(anchor_substring)
if idx < 0:
    print("  WARN: anchor line not found in WORKSPACE; skipping section 10b")
else:
    # End-of-line for the anchor
    eol = content.find('\n', idx)
    if eol < 0:
        eol = len(content)
    content = content[:eol] + new_line_after_anchor + content[eol:]
    with open(ws, 'w') as f:
        f.write(content)
    print("  OK: Patched WORKSPACE litert.patch_cmds with gpu_registry.cc dlopen rewrite")
PYEOF
else
  if [ -f "$WORKSPACE_FILE" ]; then
    echo "  SKIP: WORKSPACE already has FLUTTER_GEMMA_GPU_REGISTRY_PATCH"
  else
    echo "  WARN: $WORKSPACE_FILE not found"
  fi
fi

echo "Patch complete."
