#!/bin/bash
# Patch LiteRT-LM C API source to add:
# 1. cc_binary(linkshared=True) target for shared library (Linux dynamic-list
#    + Windows .def whitelist for the symbols our Dart FFI bindings call)
# 2. set_use_hw_masking_for_npu setter (Intel LunarLake/PantherLake NPU)
# 3. GPU smooth-UI knobs — gpu_context_low_priority + kernel_batch_size (#364)
# 4. gpu_registry.cc dlopen rewrite for App-Store-safe framework paths (Apple)
# 16. litert_lm_conversation_rewind_cancelled_turn: a stopped turn is rewound
#     instead of leaving the conversation poisoned
# 17. SentencePiece loads a BPE vocabulary with a NUL-byte piece (#659)
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
  # stream_proxy_create2, which refuses to build a proxy without all three, so a
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
    # patches/litert_openvino_2026_4_1.patch is upstream LiteRT 991d15588a
    # verbatim: the OpenVINO SDK the Windows Intel dispatch builds against and
    # ships with moves from 2026.3.1 to 2026.4.1. Intel's Gemma 4 12B bundle
    # for Panther Lake carries blob metadata 2.7, which the 2026.3 NPU plugin
    # refuses ("Imported blob metadata version: 2.7 but the current version
    # is: 2.6"). Drop the patch once the LiteRT pin contains 991d15588a.
    content = content.replace(
        '    name = "litert",\n',
        '    name = "litert",\n'
        '    patches = [\n'
        '        "//:flutter_gemma_litert_gpu_registry.patch",\n'
        '        "//:flutter_gemma_litert_google_tensor_dispatch_oss.patch",\n'
        '        "//:flutter_gemma_litert_openvino_2026_4_1.patch",\n'
        '    ],\n'
        '    patch_args = ["-p1"],\n', 1)
    if 'flutter_gemma_litert_gpu_registry.patch' not in content:
        raise SystemExit("  ERROR: could not add the gpu_registry patch to the litert archive")
    with open(ws, 'w') as f:
        f.write(content)
    print("  OK: Patched WORKSPACE litert.patch_cmds with gpu_registry.cc dlopen rewrite")
    print("  OK: litert archive applies patches/litert_gpu_registry_apple.patch")
    print("  OK: LiteRT Google Tensor dispatch drops its unused internal hooks dependency")
    print("  OK: LiteRT pins OpenVINO 2026.4.1 (upstream 991d15588a)")
PYEOF
  cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_gpu_registry_apple.patch" \
    "$DIR/flutter_gemma_litert_gpu_registry.patch"
  cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_google_tensor_dispatch_oss.patch" \
    "$DIR/flutter_gemma_litert_google_tensor_dispatch_oss.patch"
  cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_openvino_2026_4_1.patch" \
    "$DIR/flutter_gemma_litert_openvino_2026_4_1.patch"
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
    cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_gpu_registry_apple.patch" \
      "$DIR/flutter_gemma_litert_gpu_registry.patch"
    if ! grep -q "flutter_gemma_litert_openvino_2026_4_1.patch" \
        "$WORKSPACE_FILE"; then
      echo "  ERROR: $WORKSPACE_FILE has no OpenVINO 2026.4.1 patch;" \
        "start from a fresh LiteRT-LM tree" >&2
      exit 1
    fi
    cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_google_tensor_dispatch_oss.patch" \
      "$DIR/flutter_gemma_litert_google_tensor_dispatch_oss.patch"
    cp "$(cd "$(dirname "$0")" && pwd)/patches/litert_openvino_2026_4_1.patch" \
      "$DIR/flutter_gemma_litert_openvino_2026_4_1.patch"
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
grep -qF 'external_weights.sections["tflite_weights"]' "$PATHW_UTILS" ||
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
#   task has ended (Conversation::WaitUntilDone, backported from upstream main),
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
if ! grep -q "flutter_gemma_sentencepiece_nul_piece.patch" "$WORKSPACE_FILE"; then
  python3 << 'PYEOF' || exit 1
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
    raise SystemExit("  ERROR: section 17: the sentencepiece archive already "
                     "has patches; merge ours into them")
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
cp "$SP_SRC_DIR/patches/sentencepiece_nul_piece.patch" \
  "$DIR/flutter_gemma_sentencepiece_nul_piece.patch"
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

echo "Patch complete."
