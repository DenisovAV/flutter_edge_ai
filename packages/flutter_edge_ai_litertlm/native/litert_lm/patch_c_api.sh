#!/bin/bash
# Patch LiteRT-LM C API source to add:
# 1. cc_binary(linkshared=True) target for shared library (Linux dynamic-list
#    + Windows .def whitelist for the symbols our Dart FFI bindings call)
# 2. set_use_hw_masking_for_npu setter (Intel LunarLake/PantherLake NPU)
# 3. GPU smooth-UI knobs — gpu_context_low_priority + kernel_batch_size (#364)
# 4. gpu_registry.cc dlopen rewrite for App-Store-safe framework paths (Apple)
# 16. litert_lm_conversation_rewind_cancelled_turn: a stopped turn is rewound
#     instead of leaving the conversation poisoned
# 17. SentencePiece loads a BPE vocabulary with a NUL-byte piece (#659); on
#     v0.19.0 a second patch on top of upstream's, which accepts only "\0"
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
LiteRtLmStatusCode litert_lm_engine_settings_set_use_hw_masking_for_npu(\
    LiteRtLmEngineSettings* settings, bool value);\
' "$DIR/c/engine.h"
  rm -f "$DIR/c/engine.h.bak"
  echo "  OK: Added set_use_hw_masking_for_npu to c/engine.h"
else
  echo "  SKIP: c/engine.h already has set_use_hw_masking_for_npu"
fi

if ! grep -q "set_use_hw_masking_for_npu" "$DIR/c/engine.cc"; then
  sed -i.bak '/^LiteRtLmStatusCode litert_lm_engine_settings_set_activation_data_type(/i\
LiteRtLmStatusCode litert_lm_engine_settings_set_use_hw_masking_for_npu(\
    LiteRtLmEngineSettings* settings, bool value) {\
  if (!IsValidEngineSettings(settings)) {\
    return kLiteRtLmStatusInvalidArgument;\
  }\
  auto\& exec = settings->settings->GetMutableMainExecutorSettings();\
  litert::lm::NpuConfig config;\
  auto current = exec.GetBackendConfig<litert::lm::NpuConfig>();\
  if (current.ok()) {\
    config = *current;\
  }\
  config.use_hw_masking_for_npu = value;\
  exec.SetBackendConfig(config);\
  return kLiteRtLmStatusOk;\
}\
\
' "$DIR/c/engine.cc"
  rm -f "$DIR/c/engine.cc.bak"
  grep -q '^LiteRtLmStatusCode litert_lm_engine_settings_set_use_hw_masking_for_npu(' \
    "$DIR/c/engine.cc" || {
    echo "  ERROR: section 4b: the set_activation_data_type anchor moved; no impl" >&2
    exit 1
  }
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

# ── 10. Patch sampler_factory.cc + WORKSPACE for App-Store-safe dlopen on Apple ──
#
# `gpu_registry.cc` (LiteRT) and `sampler_factory.cc` (LiteRT-LM) hardcode the
# dylib basename "libLiteRtMetalAccelerator.dylib" / "libLiteRtTopKMetalSampler.dylib"
# in their dlopen calls. Native Assets bundles each prebuilt dylib as
# `<X>.framework/<X>` (Apple's required structure for iOS) — there is no flat
# `lib<X>.dylib` file in the app bundle for dyld to find by basename.
#
# Older flutter_edge_ai versions worked around this by symlinking lib*.dylib
# alongside the frameworks in `Frameworks/`, but Apple App Store Connect
# rejects that with ITMS-90432 ("Unexpected file found in Frameworks").
#
# Proper fix: rewrite the dlopen path on Apple to a relative-to-executable
# framework path, which dyld resolves natively:
#   `@executable_path/../Frameworks/<X>.framework/<X>` on macOS
#   `@executable_path/Frameworks/<X>.framework/<X>` on iOS
#
# On Apple the framework is LiteRtLmMetalAccelerator, not upstream's
# LiteRtMetalAccelerator: flutter_litert >= 3.4.0 ships a framework under the
# upstream name for its own LiteRT, an app bundle holds only one of the two,
# and Native Assets — embedded last — silently replaced flutter_litert's, whose
# LiteRT then could not register a Metal accelerator built for another LiteRT.
# build_ios.sh / build_macos.sh copy upstream's dylib under the new name.
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

# Anchor on the litert http_archive's own patch_cmds list, not on the text of a
# command inside it: v0.18.0 rewrote that command (a shell loop replaced
# `sed … third_party/*/*`) and the old anchor stopped matching.
new_line_after_anchor = """
        # FLUTTER_GEMMA_GPU_REGISTRY_PATCH — App Store ITMS-90432 fix:
        # rewrite gpu_registry.cc dlopen path on Apple to a framework path so
        # dyld resolves the bundled .framework/<X> via @executable_path. iOS
        # bundle is flat (Frameworks/), macOS bundle has Contents/Frameworks/.
        "sed -i.bak 's|\\"libLiteRtMetalAccelerator\\" SO_EXT|FLUTTER_GEMMA_METAL_FW_PATH|g' litert/runtime/accelerators/gpu_registry.cc",
        # Inject the macro definition right after the namespace opens. Its
        # non-Apple branch names SO_EXT, which LiteRT defines before the
        # namespace in older revisions and inside it since the v0.18.0 pin;
        # a macro expands where it is used, so either order works. The
        # TargetConditionals.h include must be wrapped in #if defined(__APPLE__)
        # — that header is Apple-only, Android NDK doesn't ship it. Using awk
        # to avoid sed nesting issues.
        "awk 'BEGIN{p=0} /^namespace litert::internal/ && !p {print; print \\"\\"; print \\"#if defined(__APPLE__)\\"; print \\"#include <TargetConditionals.h>\\"; print \\"#if TARGET_OS_OSX\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"@executable_path/../Frameworks/LiteRtLmMetalAccelerator.framework/LiteRtLmMetalAccelerator\\\\\\"\\"; print \\"#elif TARGET_OS_IPHONE\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"@executable_path/Frameworks/LiteRtLmMetalAccelerator.framework/LiteRtLmMetalAccelerator\\\\\\"\\"; print \\"#else\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"libLiteRtLmMetalAccelerator.dylib\\\\\\"\\"; print \\"#endif\\"; print \\"#else\\"; print \\"#define FLUTTER_GEMMA_METAL_FW_PATH \\\\\\"libLiteRtMetalAccelerator\\\\\\" SO_EXT\\"; print \\"#endif\\"; p=1; next} {print}' litert/runtime/accelerators/gpu_registry.cc > /tmp/gpu_registry.cc.new && mv /tmp/gpu_registry.cc.new litert/runtime/accelerators/gpu_registry.cc","""

# Insert our commands first in that list. They don't depend on upstream's own
# patch_cmds, so their position in it doesn't matter.
name_idx = content.find('name = "litert",')
pc_idx = content.find('patch_cmds = [', name_idx) if name_idx >= 0 else -1
end_idx = content.find('\n)', name_idx) if name_idx >= 0 else -1
if pc_idx < 0 or (end_idx >= 0 and pc_idx > end_idx):
    # Fatal, not a warning: without §10b the Apple builds dlopen the Metal
    # accelerator by its bare upstream name, which no app bundle provides, and
    # GPU silently falls back to CPU.
    raise SystemExit("  ERROR: litert patch_cmds not found in WORKSPACE; section 10b "
                     "cannot apply — re-anchor it for this LiteRT-LM revision")
else:
    at = pc_idx + len('patch_cmds = [')
    content = content[:at] + new_line_after_anchor + content[at:]
    # The Apple accelerator order and the RTLD_DEFAULT fallback are a real diff
    # (patches/litert_gpu_registry_apple.patch, copied next to WORKSPACE by the
    # shell below). Bazel applies `patches` BEFORE `patch_cmds`, and fails the
    # fetch when a hunk does not apply — the loud failure a moved upstream
    # line has to produce. The macro it uses is defined by the awk above.
    # OpenVINO 2026.4.1 (which Intel's Gemma 4 12B for Panther Lake needs) is
    # in the LiteRT pin since v0.19.0 (dcb657e8 contains 991d15588a), so the
    # backport patch is gone.
    # Intel's public Gemma 4 12B for Panther Lake carries an OpenVINO
    # GlobalGraph container v3, which the pin's dispatch refuses ("unsupported
    # container version"). patches/litert_intel_globalgraph_v3.patch is
    # upstream LiteRT PR #10843 (merge 1f3f61d0), confined to
    # litert/vendors/intel_openvino/: the v3 parser (still reads v2) and the
    # dispatch's multi-context KV-tier changes. It is exactly
    # `git diff dcb657e8 1f3f61d0 -- litert/vendors/intel_openvino`; drop it
    # once the LiteRT pin contains 1f3f61d0.
    content = content.replace(
        '    name = "litert",\n',
        '    name = "litert",\n'
        '    patches = [\n'
        '        "//:flutter_gemma_litert_gpu_registry.patch",\n'
        '        "//:flutter_gemma_litert_google_tensor_dispatch_oss.patch",\n'
        '        "//:flutter_gemma_litert_intel_globalgraph_v3.patch",\n'
        '    ],\n'
        '    patch_args = ["-p1"],\n', 1)
    if 'flutter_gemma_litert_gpu_registry.patch' not in content:
        raise SystemExit("  ERROR: could not add the gpu_registry patch to the litert archive")
    with open(ws, 'w') as f:
        f.write(content)
    print("  OK: Patched WORKSPACE litert.patch_cmds with gpu_registry.cc dlopen rewrite")
    print("  OK: litert archive applies patches/litert_gpu_registry_apple.patch")
    print("  OK: LiteRT Google Tensor dispatch drops its unused internal hooks dependency")
    print("  OK: LiteRT Intel OpenVINO dispatch reads GlobalGraph v3 (PR #10843 backport)")
PYEOF
  cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_gpu_registry_apple.patch" \
    "$DIR/flutter_gemma_litert_gpu_registry.patch"
  cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_google_tensor_dispatch_oss.patch" \
    "$DIR/flutter_gemma_litert_google_tensor_dispatch_oss.patch"
  cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_intel_globalgraph_v3.patch" \
    "$DIR/flutter_gemma_litert_intel_globalgraph_v3.patch"
else
  if [ -f "$WORKSPACE_FILE" ]; then
    # A tree patched by an older patch_c_api.sh has the sed but not the diff:
    # its Apple build still tries libLiteRtGpuAccelerator first and falls back
    # to RTLD_DEFAULT, which in an app with flutter_litert is that runtime's
    # accelerator (the litertlm 1.10.0 iOS crash). Refuse it rather than skip.
    if ! grep -q "flutter_gemma_litert_gpu_registry.patch" "$WORKSPACE_FILE"; then
      echo "  ERROR: $WORKSPACE_FILE was patched by an older patch_c_api.sh" \
        "(no gpu_registry diff); start from a fresh LiteRT-LM tree" >&2
      exit 1
    fi
    if ! grep -q "flutter_gemma_litert_google_tensor_dispatch_oss.patch" \
        "$WORKSPACE_FILE"; then
      echo "  ERROR: $WORKSPACE_FILE has no Google Tensor OSS dispatch patch;" \
        "start from a fresh LiteRT-LM tree" >&2
      exit 1
    fi
    if ! grep -q "flutter_gemma_litert_intel_globalgraph_v3.patch" \
        "$WORKSPACE_FILE"; then
      echo "  ERROR: $WORKSPACE_FILE has no Intel GlobalGraph v3 patch;" \
        "start from a fresh LiteRT-LM tree" >&2
      exit 1
    fi
    cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_gpu_registry_apple.patch" \
      "$DIR/flutter_gemma_litert_gpu_registry.patch"
    cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_google_tensor_dispatch_oss.patch" \
      "$DIR/flutter_gemma_litert_google_tensor_dispatch_oss.patch"
    cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_intel_globalgraph_v3.patch" \
      "$DIR/flutter_gemma_litert_intel_globalgraph_v3.patch"
    echo "  SKIP: WORKSPACE already has FLUTTER_GEMMA_GPU_REGISTRY_PATCH"
  else
    echo "  ERROR: $WORKSPACE_FILE not found; section 10b cannot apply" >&2
    exit 1
  fi
fi

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

# ── 12. Linux constraint-provider ABI bridge (#551) ──
# The three Gemma data processors reinterpret_cast the prebuilt provider's
# object to Constraint*. On Linux that object speaks Google's libc++ ABI and
# our runtime does not, so every native tool call aborts on its first
# constrained token. gemma_constraint_abi_bridge.h wraps it instead; on every
# other platform WrapGemmaModelConstraint is the same cast as before.
#
# Unlike the sections above, a missing anchor FAILS the patch: a WARN here
# builds a runtime that crashes on tool calls with every other check green.
BRIDGE_SRC="$(cd "$(dirname "$0")" && pwd)/gemma_constraint_abi_bridge.h"
FLUTTER_GEMMA_LITERT_LM_DIR="$DIR" FLUTTER_GEMMA_BRIDGE_SRC="$BRIDGE_SRC" python3 - <<'PYEOF'
import os, shutil, sys

root = os.environ["FLUTTER_GEMMA_LITERT_LM_DIR"]
src = os.environ["FLUTTER_GEMMA_BRIDGE_SRC"]
cd_dir = os.path.join(root, "runtime/components/constrained_decoding")
include = '#include "runtime/components/constrained_decoding/gemma_constraint_abi_bridge.h"'

def fail(msg):
    print(f"  ERROR: section 12: {msg}")
    sys.exit(1)

shutil.copyfile(src, os.path.join(cd_dir, "gemma_constraint_abi_bridge.h"))

build = os.path.join(cd_dir, "BUILD")
text = open(build).read()
if '"gemma_constraint_abi_bridge.h"' not in text:
    start = text.find('name = "gemma_model_constraint_provider_shared_lib"')
    if start < 0:
        fail("gemma_model_constraint_provider_shared_lib not found in BUILD")
    end = text.find("\n)\n", start)
    block = text[start:end]
    old_hdrs = 'hdrs = [\n        "gemma_model_constraint_provider.h",\n    ],'
    old_deps = 'deps = [\n        ":constraint",\n'
    if block.count(old_hdrs) != 1 or block.count(old_deps) != 1:
        fail("hdrs/deps layout of gemma_model_constraint_provider_shared_lib changed")
    block = block.replace(old_hdrs, 'hdrs = [\n        "gemma_constraint_abi_bridge.h",\n        "gemma_model_constraint_provider.h",\n    ],')
    block = block.replace(old_deps, old_deps + '        ":logit_mask",\n        "@com_google_absl//absl/memory",\n        "@com_google_absl//absl/types:span",\n')
    open(build, "w").write(text[:start] + block + text[end:])
    print("  OK: BUILD exports gemma_constraint_abi_bridge.h")
else:
    print("  SKIP: BUILD already exports gemma_constraint_abi_bridge.h")

cast = "return absl::WrapUnique(reinterpret_cast<Constraint*>(constraint));"
provider_include = '#include "runtime/components/constrained_decoding/gemma_model_constraint_provider.h"'
for name in ("gemma3", "gemma4", "function_gemma"):
    path = os.path.join(root, f"runtime/conversation/model_data_processor/{name}_data_processor.cc")
    code = open(path).read()
    if "WrapGemmaModelConstraint(constraint)" in code:
        print(f"  SKIP: {name}_data_processor.cc already bridged")
        continue
    if code.count(cast) != 1 or code.count(provider_include) != 1:
        fail(f"{name}_data_processor.cc: expected exactly one cast and one provider include")
    code = code.replace(provider_include, provider_include + "\n" + include)
    code = code.replace(cast, "return WrapGemmaModelConstraint(constraint);")
    open(path, "w").write(code)
    print(f"  OK: {name}_data_processor.cc returns WrapGemmaModelConstraint")
PYEOF

# ── 13. Linux/Windows: external weights read by path (EmbeddingGemma 2) ──
# A .litertlm TFLiteModel with a TFLiteWeights section reads its weights from
# a group named "tflite_weights". Upstream hands that section to the runtime
# through litert::Options::SetExternalWeightScopedFile, which stores a C++
# std::unordered_map inside the runtime's LiteRtOptionsT. On Linux and Windows
# the runtime is Google's prebuilt libLiteRt (libc++) and we are not, so the
# map is unreadable: Linux opens "tflite_weights" in the working directory and
# engine_create fails, Windows faults in libLiteRt.dll (0xC0000005).
# external_weights_by_path.{h,cc} rename the group to an absolute path of the
# bundle and shift the offsets, so the runtime maps the same bytes through its
# own path branch; GetWeightsSectionOffset reports no section, so no map is
# handed over. Apple and Android compile it out (one standard library there);
# -DLITERT_LM_FORCE_PATH_WEIGHTS turns it on for a test build.
#
# A real diff, applied like section 11, plus anchors on the assumptions the
# patch rests on: a moved upstream line fails the build here, not a user's
# engine_create.
PATHW_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
# LITERTLM_SKIP_PATH_WEIGHTS=1 builds without this section: the v0.19.0
# migration's check of whether 0.18.1's EmbeddingGemma 2 ABI fix made it
# unnecessary.
if [ "${LITERTLM_SKIP_PATH_WEIGHTS:-0}" = "1" ]; then
  echo "  SKIP: section 13 (LITERTLM_SKIP_PATH_WEIGHTS=1)"
else
for f in external_weights_by_path.h external_weights_by_path.cc \
    external_weights_by_path_test.cc; do
  cp "$PATHW_SRC_DIR/$f" "$DIR/runtime/components/$f"
done
PATHW_PATCH="$PATHW_SRC_DIR/patches/external_weights_by_path.patch"
if git -C "$DIR" apply --check "$PATHW_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$PATHW_PATCH"
  echo "  OK: TFLiteWeights are read by path on Linux and Windows"
elif git -C "$DIR" apply --reverse --check "$PATHW_PATCH" 2>/dev/null; then
  echo "  SKIP: external weights by path already applied"
else
  echo "  ERROR: $PATHW_PATCH does not apply to this LiteRT-LM revision —" >&2
  echo "         model_resources_litert_lm or runtime/components/BUILD moved;" >&2
  echo "         re-create the patch against it." >&2
  exit 1
fi
pathw_fail() {
  echo "  ERROR: section 13: $1" >&2
  exit 1
}
PATHW_UTILS="$DIR/runtime/executor/litert_compiled_model_executor_utils.cc"
# The group name the rewrite looks for is the one upstream gives the section.
# v0.19.0 also lets a model reference another model's weights as
# "tflite_weights:<model type>" (tied embeddings deduplicated across models,
# 90aac9c); this section rewrites only a model's own group, so such a bundle
# still fails on Linux and Windows.
grep -qF 'kModelWeightGroupName = "tflite_weights";' "$PATHW_UTILS" ||
  pathw_fail "GetExternalWeightResources no longer names the group \"tflite_weights\""
# NotFound from GetWeightsSectionOffset must still mean "no scoped file".
grep -qF 'absl::IsNotFound(section_offset.status())' "$PATHW_UTILS" ||
  pathw_fail "GetExternalWeightResources no longer treats NotFound as no external weights"
# Every caller of SetExternalWeightScopedFile must be fed by
# GetExternalWeightResources; a new one would hand the runtime a map again.
pathw_callers="$(grep -rlF '.SetExternalWeightScopedFile(' --include='*.cc' \
  "$DIR/runtime" "$DIR/c" | grep -v '_test\.cc$' | sed "s|^$DIR/||" | sort | tr '\n' ' ')"
[ "$pathw_callers" = "runtime/components/embedding_lookup/embedding_lookup_text.cc runtime/executor/litert_compiled_model_executor_utils.cc " ] ||
  pathw_fail "unexpected SetExternalWeightScopedFile callers: $pathw_callers"
grep -qF 'if (external_weight_file_.has_value() &&' \
  "$DIR/runtime/components/embedding_lookup/embedding_lookup_text.cc" ||
  pathw_fail "EmbeddingLookupText no longer skips an absent weight file"
# The in-memory map (SetWeightInMemoryMap) crosses the same boundary; the
# .litertlm resources must keep returning none.
if grep -q 'GetWeightInMemoryMap' "$DIR/runtime/components/model_resources_litert_lm.h"; then
  pathw_fail "ModelResourcesLitertLm now provides an in-memory weight map"
fi
echo "  OK: section 13 anchors hold"
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
# TF_LITE_AUX (every AOT NPU bundle) is loaded file-backed:
# CreateModelFromFileSection passes litert::Model::CreateFromFd a CRT
# descriptor. On Windows that is an index into one CRT's table; LiteRtLm.dll
# and the prebuilt libLiteRt.dll each link their own, so the runtime has no
# such descriptor. v0.17.0 failed engine_create ("Failed to load model from
# fd"); v0.18.0 ends the process in libLiteRt.dll with 0xC0000409. Reproduced
# on upstream's own litert_lm_advanced_main (LiteRT-LM #4023). Windows takes
# the buffer-backed path, as v0.16.0 did for every bundle. Android, Apple and
# Linux are unchanged: there a descriptor belongs to the process.
#
# A real diff on top of section 13's (same file), plus an anchor: a second
# caller of CreateFromFd would hand the runtime a descriptor again.
NOFD_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/windows_no_fd_model_loading.patch"
if git -C "$DIR" apply --check "$NOFD_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$NOFD_PATCH"
  echo "  OK: Windows loads .litertlm sections buffer-backed, never by descriptor"
elif git -C "$DIR" apply --reverse --check "$NOFD_PATCH" 2>/dev/null; then
  echo "  SKIP: Windows buffer-backed section loading already applied"
else
  echo "  ERROR: $NOFD_PATCH does not apply to this LiteRT-LM revision —" >&2
  echo "         model_resources_litert_lm.cc moved; re-create the patch against it." >&2
  exit 1
fi
nofd_callers="$(grep -rlE 'CreateFromFd\(|LiteRtCreateModelFromFd\(' --include='*.cc' \
  "$DIR/runtime" "$DIR/c" | grep -v '_test\.cc$' | sed "s|^$DIR/||" | sort | tr '\n' ' ')"
[ "$nofd_callers" = "runtime/components/model_resources_litert_lm.cc " ] || {
  echo "  ERROR: section 15: unexpected CreateFromFd callers: $nofd_callers" >&2
  exit 1
}
echo "  OK: section 15 anchors hold"

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
# empty, and a task leaves it at its end state, which is set after its
# callback.
grep -qF 'return execution_manager_lock->WaitUntilSessionDone(' \
  "$DIR/runtime/core/session_advanced.h" ||
  rewind_fail "SessionAdvanced::WaitUntilDone no longer waits for the session's tasks"
grep -qF 'session_lookup_.at(session_id)->active_tasks.empty();' \
  "$DIR/runtime/framework/resource_management/threaded_execution_manager.cc" ||
  rewind_fail "WaitUntilSessionDone no longer waits for the session's active tasks"
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
# (#4195). Upstream's diff verbatim; drop it once the pin contains it.
REWIND4197_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/rewind_bookkeeping_4197.patch"
if git -C "$DIR" apply --check "$REWIND4197_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$REWIND4197_PATCH"
  echo "  OK: rewind restores embeddings and the last prefill token (#4197)"
elif git -C "$DIR" apply --reverse --check "$REWIND4197_PATCH" 2>/dev/null; then
  echo "  SKIP: rewind bookkeeping (#4197) already applied"
else
  echo "  ERROR: $REWIND4197_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

# ── 19. Android: the statically linked GPU accelerator is OpenCL only ──
# From v0.19.0 libLiteRtLm links runtime/executor:default_static_gpu_accelerator
# on Apple and Android. On Android that is LiteRT's combined ML Drift
# accelerator, whose WebGPU delegate makes libLiteRtLm NEED
# libwebgpu_dawn.so — which this bundle does not carry (Android GPU is
# OpenCL only, see build_android.sh). LiteRT's ml_drift_cl_accelerator is the
# same accelerator without WebGPU.
ANDROID_CL_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/android_static_gpu_opencl.patch"
if grep -q 'name = "default_static_gpu_accelerator"' "$DIR/runtime/executor/BUILD"; then
  if git -C "$DIR" apply --check "$ANDROID_CL_PATCH" 2>/dev/null; then
    git -C "$DIR" apply "$ANDROID_CL_PATCH"
    echo "  OK: Android links the OpenCL-only GPU accelerator"
  elif git -C "$DIR" apply --reverse --check "$ANDROID_CL_PATCH" 2>/dev/null; then
    echo "  SKIP: Android OpenCL-only accelerator already applied"
  else
    echo "  ERROR: $ANDROID_CL_PATCH does not apply to this LiteRT-LM revision" >&2
    exit 1
  fi
fi

# ── 20. Linux and Windows: no fused GPU sampler ──
# From v0.19.0 the TopK GPU samplers are compiled from ML Drift source
# (upstream 47d7ba6, 7ea259d, 43b79e8) and runtime/components:
# default_static_gpu_samplers links the WebGPU one into libLiteRtLm on every
# non-Apple, non-Android target, including the dynamic-link mode Linux and
# Windows use (litert_runtime_link_mode=dynamic), where the accelerator itself
# stays out (it is Google's prebuilt libLiteRtWebGpuAccelerator). Our
# libstdc++/MSVC build of the sampler then crashed the first GPU decode:
# SIGSEGV in TopKWebGpuSampler::SampleToIdAndScoreBuffer on a T4,
# 0xC0000409 in LiteRtLm.dll on Arc B390 and Arc 140V. This leaves the
# sampler out in dynamic-link mode, as the accelerator already is; with no
# sampler library shipped either, the sampler factory samples on the CPU and
# the logits stay on the GPU.
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

# ── 22. NPU executor: save every KV cache buffer of a conversation ──
# LiteRT-LM keeps several conversations on one engine by saving the active
# one (CloneContext) and restoring the next (RestoreContext). The NPU
# executor saved only the KV buffers its prefill signature takes; a layer
# only the decode signature reads (Gemma 4 E2B on the Qualcomm SM8750
# bundle: kv_cache_k_14 and kv_cache_v_14 of 30) kept the previous
# conversation's values, measured on a DDP Galaxy S25 Ultra 2026-11-02 (N1,
# doc/research/npu-0.19.md): every conversation then answered with the last
# one's fact. Saving every buffer in input_kv_cache_buffers covers them;
# RestoreContext already restores whatever was saved.
NPU_SAVE_ALL_KV_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/npu_context_save_all_kv.patch"
if git -C "$DIR" apply --check "$NPU_SAVE_ALL_KV_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$NPU_SAVE_ALL_KV_PATCH"
  echo "  OK: NPU CloneContext saves every KV cache buffer"
elif git -C "$DIR" apply --reverse --check "$NPU_SAVE_ALL_KV_PATCH" 2>/dev/null; then
  echo "  SKIP: NPU CloneContext already saves every KV cache buffer"
else
  echo "  ERROR: $NPU_SAVE_ALL_KV_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

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
# After a rewind (section 16, or upstream's own rewind_to_checkpoint) the
# executor's step is back at the checkpoint, but its processed tokens still
# hold what the stopped send prefilled and decoded. The resource manager's
# prefill drops the input tokens that match them and, when they all match
# (the stopped exchange of a stopped reply usually does: it ends with the
# reply's last token, which the executor holds as its pending token), calls
# the executor with the step after them in the prefill params only. The
# executor takes its step from SetCurrentStep, so the rest of the input was
# prefilled from the checkpoint's step and the matched tokens were lost:
# Gemma 4 E2B rewound with "The salt-laced wind was Elara's" held 5 tokens
# instead of 34 and forgot the conversation (macOS CPU and Metal, 2026-11-04,
# probe command convrewind). The other branch already sets the step.
MATCHED_STEP_PATCH="$(cd "$(dirname "$0")" && pwd)/patches/resource_manager_matched_step.patch"
if git -C "$DIR" apply --check "$MATCHED_STEP_PATCH" 2>/dev/null; then
  git -C "$DIR" apply "$MATCHED_STEP_PATCH"
  echo "  OK: a prefill after a rewind keeps the matched tokens' step"
elif git -C "$DIR" apply --reverse --check "$MATCHED_STEP_PATCH" 2>/dev/null; then
  echo "  SKIP: matched-step fix already applied"
else
  echo "  ERROR: $MATCHED_STEP_PATCH does not apply to this LiteRT-LM revision" >&2
  exit 1
fi

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

echo "Patch complete."
