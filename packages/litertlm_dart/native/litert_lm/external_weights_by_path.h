// flutter_gemma patch (section 13): external weights addressed by path.
//
// Copied into runtime/components/ by patch_c_api.sh (section 13), with its
// .cc and test. ModelResourcesLitertLm::GetTFLiteModel calls
// AddressWeightsByPath for every TFLiteModel section that has a TFLiteWeights
// section, and GetWeightsSectionOffset reports none, so nothing reaches
// litert::Options::SetExternalWeightScopedFile.
//
// Why: SetExternalWeightScopedFile (litert/cc/litert_options.h at LiteRT
// 26895c9f) reinterpret_casts the runtime-owned LiteRtOptionsT and stores a
// std::unique_ptr<ScopedWeightSource> whose std::unordered_map<std::string, …>
// the runtime later looks up and destroys. On Linux and Windows libLiteRtLm is
// built against Google's prebuilt libLiteRt (libc++, std::__u) with our own
// standard library (libstdc++, the MSVC STL), so the runtime reads a container
// of another library:
//   * Linux: the lookup misses, the weights are opened as "tflite_weights"
//     relative to the working directory (ENOENT), and an EmbeddingGemma 2
//     engine fails to create;
//   * Windows: libc++'s find() on an MSVC unordered_map faults (0xC0000005 in
//     libLiteRt.dll).
// The prebuilt has no C entry point for external weights, and rebuilding the
// runtime with our standard library breaks Google's closed WebGPU accelerator.
//
// Instead the model flatbuffer itself names the weights: every external-buffer
// group called "tflite_weights" is renamed to an absolute path of the
// .litertlm bundle, and every ExternalBuffer offset in it is moved by the
// TFLiteWeights section's begin. The runtime's own path branch
// (weight_loader/external_weight_loader_litert.cc: ResolveGroupPath, then
// open/fstat/mmap) maps the same bytes the scoped file would have. Only bytes
// cross the boundary. Measured: embeddings bit-identical to the scoped path
// (macOS) and to the litert-lm wheel (Linux, Google's libLiteRt.so).
//
// The flatbuffer is repacked (object API), not patched in place: the
// converter omits the offset field of buffers at offset 0, so there is no
// field to write into.

#ifndef FLUTTER_GEMMA_EXTERNAL_WEIGHTS_BY_PATH_H_
#define FLUTTER_GEMMA_EXTERNAL_WEIGHTS_BY_PATH_H_

#include <cstdint>
#include <optional>
#include <string>

#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "absl/types/span.h"  // from @com_google_absl
#include "litert/cc/litert_buffer_ref.h"  // from @litert
#include "runtime/util/scoped_file.h"

// Platforms whose libLiteRtLm loads Google's prebuilt runtime with another
// standard library. LITERT_LM_FORCE_PATH_WEIGHTS turns the path on elsewhere,
// for testing it against the scoped path on a platform where both work.
#if (defined(__linux__) && !defined(__ANDROID__)) || defined(_WIN32) || \
    defined(LITERT_LM_FORCE_PATH_WEIGHTS)
#define LITERT_LM_PATH_WEIGHTS 1
#else
#define LITERT_LM_PATH_WEIGHTS 0
#endif

namespace litert::lm::external_weights_by_path {

// The external-buffer group name LiteRT-LM gives a TFLiteWeights section
// (GetExternalWeightResources in litert_compiled_model_executor_utils.cc).
inline constexpr absl::string_view kWeightsGroupName = "tflite_weights";

// A model whose external weights are read by path. Both members must outlive
// the litert::Model created from `flatbuffer`.
struct PathAddressedModel {
  litert::OwningBufferRef<uint8_t> flatbuffer;
  // Linux/Android: the descriptor behind /proc/self/fd/N. Invalid elsewhere.
  ScopedFile keep_alive;
};

// An absolute path that opens the same file as `bundle`, and what keeps it
// valid.
struct BundlePath {
  std::string path;
  ScopedFile keep_alive;
};

// Linux/Android: /proc/self/fd/<a close-on-exec duplicate of `bundle`>.
// Apple: fcntl(F_GETPATH). Windows: GetFinalPathNameByHandleW, reduced to
// ASCII through its 8.3 short name if needed, because the runtime opens the
// path with CreateFileA and std::ifstream. Every platform checks that the
// path opens `bundle` itself; a path that cannot is an error, not a fallback.
absl::StatusOr<BundlePath> AbsolutePathOf(const ScopedFile& bundle);

// Rewrites the TFLite flatbuffer `model` so that every external buffer in a
// group named `group_name` is read from `absolute_path` at
// `section_begin + offset`, after checking that it lies inside the section
// (`section_size` bytes). Returns std::nullopt when no external buffer belongs
// to such a group: the model then needs nothing from the section. Refuses a
// model with appended buffer data (Buffer.offset > 1), which a repack would
// move.
absl::StatusOr<std::optional<litert::OwningBufferRef<uint8_t>>> RewriteToPath(
    absl::Span<const uint8_t> model, absl::string_view group_name,
    absl::string_view absolute_path, uint64_t section_begin,
    uint64_t section_size);

// AbsolutePathOf(bundle) + RewriteToPath(model, kWeightsGroupName, …) for one
// TFLiteModel section whose TFLiteWeights section is [section_begin,
// section_begin + section_size) of `bundle`.
absl::StatusOr<std::optional<PathAddressedModel>> AddressWeightsByPath(
    absl::Span<const uint8_t> model, const ScopedFile& bundle,
    uint64_t section_begin, uint64_t section_size);

}  // namespace litert::lm::external_weights_by_path

#endif  // FLUTTER_GEMMA_EXTERNAL_WEIGHTS_BY_PATH_H_
