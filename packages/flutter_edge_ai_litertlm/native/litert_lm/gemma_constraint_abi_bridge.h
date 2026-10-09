// flutter_gemma patch (#551): bridge to the prebuilt Linux constraint provider.
//
// Copied into runtime/components/constrained_decoding/ by patch_c_api.sh
// (section 12). The three Gemma data processors return
// WrapGemmaModelConstraint(constraint) where upstream returns
// absl::WrapUnique(reinterpret_cast<Constraint*>(constraint)).
//
// Why: LiteRtLmGemmaModelConstraintProvider_CreateConstraintFromTools is a C
// entry point that returns a C++ object, and upstream's runtime calls it
// through its own Constraint vtable. On Android, Apple and Windows the
// prebuilt provider and our runtime are built by the same platform toolchain,
// so that works. On Linux the provider is built by Google's toolchain (libc++
// with inline namespace std::__u) and our runtime by clang + libstdc++, and
// the two disagree on exactly the things that cross this boundary — measured
// in the prebuilt binaries (x86_64 sha256 f5970d28…, PREBUILT_REF 4453b286):
//
//   * Start() returns std::unique_ptr<State> in a register (rax / x0): the
//     provider's unique_ptr is trivial_abi. Our caller passes a hidden return
//     slot instead, so the provider takes the slot for `this` and every tool
//     call aborts on the first constrained token.
//   * Its std::vector stores {begin, size, capacity}, while the runtime reads
//     BitmapLogitMask::words_ as {begin, end, end_of_storage}.
//
// What does NOT differ, and is relied on below: the vtable slot order (it is
// the open-source constraint.h / logit_mask.h order), deleting destructors,
// and absl::StatusOr<std::unique_ptr<T>> — non-trivial in both ABIs, so
// returned through a hidden slot, laid out as {uintptr_t rep, T* ptr} with
// rep == 1 for OK.
//
// So on Linux the provider object is wrapped instead of reinterpreted: each
// call goes through its own convention, and each mask is copied into our own
// BitmapLogitMask before the runtime sees it. The layout facts are tied to the
// provider binary, which only changes when PREBUILT_REF moves; when it does,
// litertlm_native_tools_test on Linux x86_64 and arm64 is the gate.

#ifndef FLUTTER_GEMMA_GEMMA_CONSTRAINT_ABI_BRIDGE_H_
#define FLUTTER_GEMMA_GEMMA_CONSTRAINT_ABI_BRIDGE_H_

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>

#include "absl/memory/memory.h"  // from @com_google_absl
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/types/span.h"  // from @com_google_absl
#include "runtime/components/constrained_decoding/constraint.h"
#include "runtime/components/constrained_decoding/gemma_model_constraint_provider.h"
#include "runtime/components/constrained_decoding/logit_mask.h"

namespace litert::lm {

#if defined(__linux__) && !defined(__ANDROID__)

namespace gemma_constraint_abi {

// Vtable slots, counted from the address point.
// Constraint: ~D1, ~D0, Start, IsEnded, GetVocabularySize, ComputeNext,
// ComputeMask, ComputeBitmap. LogitMask: ~D1, ~D0, GetType, Apply(float),
// Apply(half). State: ~D1, ~D0.
inline constexpr int kDeletingDtor = 1;
inline constexpr int kStart = 2;
inline constexpr int kIsEnded = 3;
inline constexpr int kGetVocabularySize = 4;
inline constexpr int kComputeNext = 5;
inline constexpr int kComputeMask = 6;
inline constexpr int kMaskGetType = 2;

// absl::Status rep of OK, and the provider's BitmapLogitMask field offsets.
inline constexpr uintptr_t kOkRep = 1;
inline constexpr size_t kMaskVocabSizeOffset = 0x08;
inline constexpr size_t kMaskWordsBeginOffset = 0x10;
inline constexpr size_t kMaskWordsCountOffset = 0x18;

// The provider's StatusOr<unique_ptr<T>>. The user-provided destructor makes
// it non-trivial for the purposes of calls, so it is returned through a hidden
// slot (rdi / x8) — the provider's own convention for this type.
struct ForeignStatusOrPtr {
  uintptr_t rep;
  void* ptr;
  ~ForeignStatusOrPtr() {}
};
static_assert(sizeof(ForeignStatusOrPtr) == 16);

template <typename Fn>
Fn Slot(const void* object, int index) {
  void* const* vtable;
  std::memcpy(&vtable, object, sizeof(vtable));
  return reinterpret_cast<Fn>(vtable[index]);
}

inline void DeleteForeign(void* object) {
  if (object != nullptr) {
    Slot<void (*)(void*)>(object, kDeletingDtor)(object);
  }
}

template <typename T>
T ReadField(const void* object, size_t offset) {
  T value;
  std::memcpy(&value, static_cast<const char*>(object) + offset, sizeof(T));
  return value;
}

// The rep is leaked on purpose: releasing it needs the provider's own absl,
// which it does not export, and this path only runs when the provider rejects
// a token the decoder itself let through.
inline absl::Status ForeignError(const char* method, uintptr_t rep) {
  int code = -1;
  if ((rep & 1) != 0) {
    code = static_cast<int>(rep >> 2);  // inlined rep: code << 2 | 1
  } else if (rep != 0) {
    code = ReadField<int32_t>(reinterpret_cast<const void*>(rep), 4);
  }
  return absl::InternalError(
      std::string("Gemma constraint provider: ") + method +
      " failed (absl status code " + std::to_string(code) + ")");
}

class ForeignState final : public Constraint::State {
 public:
  explicit ForeignState(void* state) : state_(state) {}
  ~ForeignState() override { DeleteForeign(state_); }
  ForeignState(const ForeignState&) = delete;
  ForeignState& operator=(const ForeignState&) = delete;
  const void* get() const { return state_; }

 private:
  void* state_;
};

class ForeignGemmaConstraint final : public Constraint {
 public:
  explicit ForeignGemmaConstraint(void* constraint) : constraint_(constraint) {}
  ~ForeignGemmaConstraint() override { DeleteForeign(constraint_); }
  ForeignGemmaConstraint(const ForeignGemmaConstraint&) = delete;
  ForeignGemmaConstraint& operator=(const ForeignGemmaConstraint&) = delete;

  std::unique_ptr<State> Start() const override {
    // trivial_abi unique_ptr: a raw pointer in the return register.
    void* state = Slot<void* (*)(const void*)>(constraint_, kStart)(constraint_);
    return std::make_unique<ForeignState>(state);
  }

  bool IsEnded(const State& state) const override {
    return Slot<bool (*)(const void*, const void*)>(constraint_, kIsEnded)(
        constraint_, Unwrap(state));
  }

  int GetVocabularySize() const override {
    return Slot<int (*)(const void*)>(constraint_, kGetVocabularySize)(
        constraint_);
  }

  absl::StatusOr<std::unique_ptr<State>> ComputeNext(const State& state,
                                                     int token) const override {
    ForeignStatusOrPtr result =
        Slot<ForeignStatusOrPtr (*)(const void*, const void*, int)>(
            constraint_, kComputeNext)(constraint_, Unwrap(state), token);
    if (result.rep != kOkRep) return ForeignError("ComputeNext", result.rep);
    return std::make_unique<ForeignState>(result.ptr);
  }

  absl::StatusOr<std::unique_ptr<LogitMask>> ComputeMask(
      const State& state) const override {
    ForeignStatusOrPtr result =
        Slot<ForeignStatusOrPtr (*)(const void*, const void*)>(
            constraint_, kComputeMask)(constraint_, Unwrap(state));
    if (result.rep != kOkRep) return ForeignError("ComputeMask", result.rep);
    void* mask = result.ptr;
    if (mask == nullptr) {
      return BitmapLogitMask::CreateAllAllowed(GetVocabularySize());
    }
    const int type = Slot<int (*)(const void*)>(mask, kMaskGetType)(mask);
    const int vocab_size = ReadField<int>(mask, kMaskVocabSizeOffset);
    const auto* words =
        ReadField<const uint64_t*>(mask, kMaskWordsBeginOffset);
    const auto count = ReadField<size_t>(mask, kMaskWordsCountOffset);
    // Every check below holds for the binary this bridge was measured on; a
    // provider with another layout fails loudly here instead of reading
    // garbage.
    const bool layout_ok =
        type == static_cast<int>(MaskType::kBitmap) &&
        vocab_size == GetVocabularySize() && vocab_size > 0 &&
        words != nullptr &&
        count >= static_cast<size_t>((vocab_size + 63) / 64) &&
        count < (size_t{1} << 26);
    std::unique_ptr<LogitMask> copy;
    if (layout_ok) {
      copy = std::make_unique<BitmapLogitMask>(
          vocab_size, absl::Span<const uint64_t>(words, count));
    }
    DeleteForeign(mask);
    if (!layout_ok) {
      return absl::InternalError(
          "Gemma constraint provider: the logit mask does not have the "
          "layout this runtime was built against. The prebuilt provider "
          "changed; re-measure gemma_constraint_abi_bridge.h.");
    }
    return copy;
  }

 private:
  static const void* Unwrap(const State& state) {
    return static_cast<const ForeignState&>(state).get();
  }

  void* constraint_;
};

}  // namespace gemma_constraint_abi

inline std::unique_ptr<Constraint> WrapGemmaModelConstraint(
    LiteRtLmConstraint* constraint) {
  return std::make_unique<gemma_constraint_abi::ForeignGemmaConstraint>(
      constraint);
}

#else  // Android, Apple, Windows: provider and runtime share one ABI.

inline std::unique_ptr<Constraint> WrapGemmaModelConstraint(
    LiteRtLmConstraint* constraint) {
  return absl::WrapUnique(reinterpret_cast<Constraint*>(constraint));
}

#endif

}  // namespace litert::lm

#endif  // FLUTTER_GEMMA_GEMMA_CONSTRAINT_ABI_BRIDGE_H_
