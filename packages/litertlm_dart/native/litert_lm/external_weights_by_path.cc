// flutter_gemma patch (section 13): see external_weights_by_path.h.

#include "runtime/components/external_weights_by_path.h"

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/param.h>
#endif
#endif

#include "absl/log/absl_log.h"  // from @com_google_absl
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/str_cat.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "absl/types/span.h"  // from @com_google_absl
#include "flatbuffers/flatbuffers.h"  // from @flatbuffers
#include "litert/cc/litert_buffer_ref.h"  // from @litert
#include "runtime/util/scoped_file.h"
#include "tflite/schema/schema_generated.h"  // from @litert

namespace litert::lm::external_weights_by_path {
namespace {

constexpr absl::string_view kWhat =
    "external weights by path (flutter_gemma patch section 13)";

bool VerifyModel(absl::Span<const uint8_t> model) {
  if (model.empty()) return false;
  flatbuffers::Verifier verifier(model.data(), model.size());
  return tflite::VerifyModelBuffer(verifier);
}

template <typename Vector>
size_t Count(const Vector* vector) {
  return vector == nullptr ? 0 : vector->size();
}

// in_group[g] is true when external-buffer group g is called `group_name`.
std::vector<bool> GroupsNamed(const tflite::Model& model,
                              absl::string_view group_name) {
  std::vector<bool> in_group(Count(model.external_buffer_groups()), false);
  for (size_t g = 0; g < in_group.size(); ++g) {
    const tflite::ExternalBufferGroup* group =
        model.external_buffer_groups()->Get(g);
    in_group[g] = group != nullptr && group->name() != nullptr &&
                  absl::string_view(group->name()->c_str(),
                                    group->name()->size()) == group_name;
  }
  return in_group;
}

bool UsesAny(const tflite::Model& model, const std::vector<bool>& in_group) {
  if (model.external_buffers() == nullptr) return false;
  for (const tflite::ExternalBuffer* external : *model.external_buffers()) {
    if (external != nullptr && external->group() < in_group.size() &&
        in_group[external->group()]) {
      return true;
    }
  }
  return false;
}

// Everything the repack must not change: counts of every top-level vector,
// subgraph shapes, inline buffer sizes, and the identity of every external
// buffer. Offsets are compared by the caller, which knows the shift.
bool SameStructure(const tflite::Model& a, const tflite::Model& b) {
  if (a.version() != b.version() ||
      Count(a.operator_codes()) != Count(b.operator_codes()) ||
      Count(a.subgraphs()) != Count(b.subgraphs()) ||
      Count(a.buffers()) != Count(b.buffers()) ||
      Count(a.metadata_buffer()) != Count(b.metadata_buffer()) ||
      Count(a.metadata()) != Count(b.metadata()) ||
      Count(a.signature_defs()) != Count(b.signature_defs()) ||
      Count(a.external_buffer_groups()) != Count(b.external_buffer_groups()) ||
      Count(a.external_buffers()) != Count(b.external_buffers())) {
    return false;
  }
  for (size_t i = 0; i < Count(a.subgraphs()); ++i) {
    const tflite::SubGraph* x = a.subgraphs()->Get(i);
    const tflite::SubGraph* y = b.subgraphs()->Get(i);
    if ((x == nullptr) != (y == nullptr)) return false;
    if (x == nullptr) continue;
    if (Count(x->tensors()) != Count(y->tensors()) ||
        Count(x->operators()) != Count(y->operators()) ||
        Count(x->inputs()) != Count(y->inputs()) ||
        Count(x->outputs()) != Count(y->outputs())) {
      return false;
    }
  }
  for (size_t i = 0; i < Count(a.buffers()); ++i) {
    const tflite::Buffer* x = a.buffers()->Get(i);
    const tflite::Buffer* y = b.buffers()->Get(i);
    if ((x == nullptr) != (y == nullptr)) return false;
    if (x != nullptr && Count(x->data()) != Count(y->data())) return false;
  }
  for (size_t i = 0; i < Count(a.external_buffers()); ++i) {
    const tflite::ExternalBuffer* x = a.external_buffers()->Get(i);
    const tflite::ExternalBuffer* y = b.external_buffers()->Get(i);
    if ((x == nullptr) != (y == nullptr)) return false;
    if (x != nullptr &&
        (x->id() != y->id() || x->group() != y->group() ||
         x->length() != y->length())) {
      return false;
    }
  }
  return true;
}

#if defined(_WIN32)

bool IsAscii(const std::wstring& path) {
  for (wchar_t c : path) {
    if (c == 0 || c > 0x7f) return false;
  }
  return true;
}

absl::StatusOr<std::wstring> FinalPathName(HANDLE file) {
  constexpr DWORD kFlags = FILE_NAME_NORMALIZED | VOLUME_NAME_DOS;
  const DWORD needed = GetFinalPathNameByHandleW(file, nullptr, 0, kFlags);
  if (needed == 0) {
    return absl::InternalError(absl::StrCat(
        kWhat, ": GetFinalPathNameByHandleW failed (error ", GetLastError(),
        ")"));
  }
  std::wstring path(needed, L'\0');
  const DWORD written =
      GetFinalPathNameByHandleW(file, path.data(), needed, kFlags);
  if (written == 0 || written >= needed) {
    return absl::InternalError(absl::StrCat(
        kWhat, ": GetFinalPathNameByHandleW failed (error ", GetLastError(),
        ")"));
  }
  path.resize(written);
  return path;
}

absl::StatusOr<std::wstring> ShortPathName(const std::wstring& path) {
  const DWORD needed = GetShortPathNameW(path.c_str(), nullptr, 0);
  if (needed == 0) {
    return absl::FailedPreconditionError(absl::StrCat(
        kWhat, ": the model path is not ASCII and has no 8.3 short name "
               "(GetShortPathNameW error ",
        GetLastError(), ")"));
  }
  std::wstring short_path(needed, L'\0');
  const DWORD written =
      GetShortPathNameW(path.c_str(), short_path.data(), needed);
  if (written == 0 || written >= needed) {
    return absl::FailedPreconditionError(absl::StrCat(
        kWhat, ": GetShortPathNameW failed (error ", GetLastError(), ")"));
  }
  short_path.resize(written);
  return short_path;
}

// CreateFileA needs the \\?\ form only beyond MAX_PATH; keep it there.
std::wstring WithoutVerbatimPrefix(const std::wstring& path) {
  const std::wstring unc = L"\\\\?\\UNC\\";
  const std::wstring local = L"\\\\?\\";
  std::wstring plain;
  if (path.compare(0, unc.size(), unc) == 0) {
    plain = L"\\\\" + path.substr(unc.size());
  } else if (path.compare(0, local.size(), local) == 0) {
    plain = path.substr(local.size());
  } else {
    return path;
  }
  return plain.size() < MAX_PATH ? plain : path;
}

// Opens `path` the way the runtime does (CreateFileA, GENERIC_READ,
// FILE_SHARE_READ) and checks it is the model file.
absl::Status CheckSameFile(const ScopedFile& bundle, const std::string& path) {
  BY_HANDLE_FILE_INFORMATION want;
  if (!GetFileInformationByHandle(bundle.file(), &want)) {
    return absl::InternalError(absl::StrCat(
        kWhat, ": GetFileInformationByHandle failed (error ", GetLastError(),
        ")"));
  }
  HANDLE opened = CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (opened == INVALID_HANDLE_VALUE) {
    return absl::FailedPreconditionError(absl::StrCat(
        kWhat, ": the runtime would not be able to open ", path,
        " (CreateFileA error ", GetLastError(),
        "); is the model file open for writing elsewhere?"));
  }
  BY_HANDLE_FILE_INFORMATION got;
  const BOOL ok = GetFileInformationByHandle(opened, &got);
  CloseHandle(opened);
  if (!ok || want.dwVolumeSerialNumber != got.dwVolumeSerialNumber ||
      want.nFileIndexHigh != got.nFileIndexHigh ||
      want.nFileIndexLow != got.nFileIndexLow) {
    return absl::FailedPreconditionError(
        absl::StrCat(kWhat, ": ", path, " does not open the model file"));
  }
  return absl::OkStatus();
}

#else  // POSIX

#if defined(__APPLE__)
constexpr absl::string_view kStatHint = "";
#else
constexpr absl::string_view kStatHint = " (is /proc mounted?)";
#endif

absl::Status CheckSameFile(const ScopedFile& bundle, const std::string& path) {
  struct stat want;
  struct stat got;
  if (fstat(bundle.file(), &want) != 0) {
    return absl::InternalError(absl::StrCat(
        kWhat, ": fstat of the model file failed: ", std::strerror(errno)));
  }
  if (stat(path.c_str(), &got) != 0) {
    return absl::FailedPreconditionError(absl::StrCat(
        kWhat, ": cannot stat ", path, ": ", std::strerror(errno), kStatHint));
  }
  if (want.st_dev != got.st_dev || want.st_ino != got.st_ino) {
    return absl::FailedPreconditionError(
        absl::StrCat(kWhat, ": ", path, " does not open the model file"));
  }
  return absl::OkStatus();
}

#endif

}  // namespace

absl::StatusOr<BundlePath> AbsolutePathOf(const ScopedFile& bundle) {
  if (!bundle.IsValid()) {
    return absl::FailedPreconditionError(
        absl::StrCat(kWhat, ": the model has no open file"));
  }
  BundlePath result;
#if defined(_WIN32)
  absl::StatusOr<std::wstring> wide = FinalPathName(bundle.file());
  if (!wide.ok()) return wide.status();
  if (!IsAscii(*wide)) {
    // The runtime opens external weights with CreateFileA and std::ifstream,
    // which read the path in the ANSI code page.
    wide = ShortPathName(*wide);
    if (!wide.ok()) return wide.status();
    if (!IsAscii(*wide)) {
      return absl::FailedPreconditionError(absl::StrCat(
          kWhat,
          ": the model path contains non-ASCII characters and its 8.3 short "
          "name does too, so LiteRT cannot open the weights (it uses "
          "CreateFileA). Move the model to a path with ASCII characters "
          "only."));
    }
  }
  const std::wstring plain = WithoutVerbatimPrefix(*wide);
  result.path.reserve(plain.size());
  for (wchar_t c : plain) result.path.push_back(static_cast<char>(c));
#elif defined(__APPLE__)
  char buffer[MAXPATHLEN];
  if (fcntl(bundle.file(), F_GETPATH, buffer) == -1) {
    return absl::InternalError(absl::StrCat(
        kWhat, ": fcntl(F_GETPATH) failed: ", std::strerror(errno)));
  }
  result.path = buffer;
#else
  // A descriptor of our own, close-on-exec, so the path stays valid for as
  // long as the model whatever happens to the file's name meanwhile.
  const int fd = fcntl(bundle.file(), F_DUPFD_CLOEXEC, 0);
  if (fd < 0) {
    return absl::InternalError(
        absl::StrCat(kWhat, ": cannot duplicate the model file descriptor: ",
                     std::strerror(errno)));
  }
  result.keep_alive = ScopedFile(fd);
  result.path = absl::StrCat("/proc/self/fd/", fd);
#endif
  if (absl::Status same = CheckSameFile(bundle, result.path); !same.ok()) {
    return same;
  }
  return absl::StatusOr<BundlePath>(std::move(result));
}

absl::StatusOr<std::optional<litert::OwningBufferRef<uint8_t>>> RewriteToPath(
    absl::Span<const uint8_t> model, absl::string_view group_name,
    absl::string_view absolute_path, uint64_t section_begin,
    uint64_t section_size) {
  if (!VerifyModel(model)) {
    return absl::InvalidArgumentError(absl::StrCat(
        kWhat, ": the model section is not a valid TFLite flatbuffer"));
  }
  const tflite::Model* original = tflite::GetModel(model.data());
  const std::vector<bool> in_group = GroupsNamed(*original, group_name);
  if (!UsesAny(*original, in_group)) return std::nullopt;

  if (absolute_path.empty()) {
    return absl::InvalidArgumentError(
        absl::StrCat(kWhat, ": empty weights path"));
  }
  // Parenthesized: <windows.h> may arrive (through scoped_file.h) without
  // NOMINMAX, and then `max` is a macro.
  if (section_begin > (std::numeric_limits<uint64_t>::max)() - section_size) {
    return absl::InvalidArgumentError(
        absl::StrCat(kWhat, ": the weights section overflows"));
  }
  if (original->buffers() != nullptr) {
    for (size_t i = 0; i < original->buffers()->size(); ++i) {
      const tflite::Buffer* buffer = original->buffers()->Get(i);
      if (buffer != nullptr && buffer->offset() > 1) {
        return absl::FailedPreconditionError(absl::StrCat(
            kWhat, ": buffer ", i,
            " stores its data after the flatbuffer (offset ", buffer->offset(),
            "); repacking would move it"));
      }
    }
  }

  std::unique_ptr<tflite::ModelT> unpacked(original->UnPack());
  for (size_t g = 0; g < unpacked->external_buffer_groups.size(); ++g) {
    if (in_group[g] && unpacked->external_buffer_groups[g] != nullptr) {
      unpacked->external_buffer_groups[g]->name = std::string(absolute_path);
    }
  }
  for (auto& external : unpacked->external_buffers) {
    if (external == nullptr || external->group >= in_group.size() ||
        !in_group[external->group]) {
      continue;
    }
    if (external->offset > section_size ||
        external->length > section_size - external->offset) {
      return absl::InvalidArgumentError(absl::StrCat(
          kWhat, ": external buffer ", external->id, " (offset ",
          external->offset, ", length ", external->length,
          ") lies outside its ", section_size, "-byte weights section"));
    }
    external->offset += section_begin;
  }

  flatbuffers::FlatBufferBuilder builder(model.size() + absolute_path.size() +
                                         4096);
  tflite::FinishModelBuffer(builder,
                            tflite::Model::Pack(builder, unpacked.get()));
  unpacked.reset();
  litert::OwningBufferRef<uint8_t> rewritten;
  {
    auto [data, size, offset] = rewritten.GetWeak();
    data = builder.ReleaseRaw(size, offset);
  }

  const absl::Span<const uint8_t> bytes(rewritten.Data(), rewritten.Size());
  if (!VerifyModel(bytes) ||
      !SameStructure(*original, *tflite::GetModel(bytes.data()))) {
    return absl::InternalError(absl::StrCat(
        kWhat, ": the repacked model does not match the original"));
  }
  return std::optional<litert::OwningBufferRef<uint8_t>>(std::move(rewritten));
}

absl::StatusOr<std::optional<PathAddressedModel>> AddressWeightsByPath(
    absl::Span<const uint8_t> model, const ScopedFile& bundle,
    uint64_t section_begin, uint64_t section_size) {
  // Nothing to do (and no descriptor to duplicate) unless the model reads the
  // section.
  if (!VerifyModel(model)) {
    return absl::InvalidArgumentError(absl::StrCat(
        kWhat, ": the model section is not a valid TFLite flatbuffer"));
  }
  const tflite::Model* original = tflite::GetModel(model.data());
  if (!UsesAny(*original, GroupsNamed(*original, kWeightsGroupName))) {
    return std::nullopt;
  }

  absl::StatusOr<BundlePath> path = AbsolutePathOf(bundle);
  if (!path.ok()) return path.status();
  absl::StatusOr<std::optional<litert::OwningBufferRef<uint8_t>>> rewritten =
      RewriteToPath(model, kWeightsGroupName, path->path, section_begin,
                    section_size);
  if (!rewritten.ok()) return rewritten.status();
  if (!rewritten->has_value()) return std::nullopt;

  ABSL_LOG(INFO) << "External weights [" << section_begin << ", +"
                 << section_size << ") are read from " << path->path
                 << " (flutter_gemma patch section 13)";
  PathAddressedModel result{std::move(**rewritten),
                            std::move(path->keep_alive)};
  return std::optional<PathAddressedModel>(std::move(result));
}

}  // namespace litert::lm::external_weights_by_path
