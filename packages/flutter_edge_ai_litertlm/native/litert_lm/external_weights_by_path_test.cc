// flutter_gemma patch (section 13): tests for external_weights_by_path.

#include "runtime/components/external_weights_by_path.h"

#include <cstdint>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/types/span.h"  // from @com_google_absl
#include "flatbuffers/flatbuffers.h"  // from @flatbuffers
#include "runtime/util/scoped_file.h"
#include "tflite/schema/schema_generated.h"  // from @litert

namespace litert::lm::external_weights_by_path {
namespace {

constexpr char kPath[] = "/models/bundle.litertlm";
constexpr uint64_t kSectionBegin = 1 << 20;
constexpr uint64_t kSectionSize = 4096;

struct ModelSpec {
  // The group the two weight tensors read from.
  std::string group_name = "tflite_weights";
  bool with_external_buffers = true;
  uint64_t second_offset = 128;
  // Buffer 1 keeps its data after the flatbuffer (models over 2 GB).
  bool appended_buffer = false;
};

// A model shaped like an EmbeddingGemma 2 section: group 0 is unnamed, group 1
// holds the weights, the first external buffer sits at offset 0 (so the
// serializer omits its offset field) and an inline buffer sits beside them.
std::vector<uint8_t> BuildModel(const ModelSpec& spec) {
  tflite::ModelT model;
  model.version = 3;
  model.buffers.push_back(std::make_unique<tflite::BufferT>());
  auto inline_buffer = std::make_unique<tflite::BufferT>();
  if (spec.appended_buffer) {
    inline_buffer->offset = 1 << 16;
    inline_buffer->size = 16;
  } else {
    inline_buffer->data = {1, 2, 3, 4, 5, 6, 7, 8};
  }
  model.buffers.push_back(std::move(inline_buffer));

  auto subgraph = std::make_unique<tflite::SubGraphT>();
  for (int i = 0; i < 3; ++i) {
    auto tensor = std::make_unique<tflite::TensorT>();
    tensor->name = "t" + std::to_string(i);
    tensor->shape = {2, 4};
    tensor->type = tflite::TensorType_FLOAT32;
    subgraph->tensors.push_back(std::move(tensor));
  }
  subgraph->tensors[0]->buffer = 1;
  if (spec.with_external_buffers) {
    subgraph->tensors[1]->external_buffer = 1;
    subgraph->tensors[2]->external_buffer = 2;
  }
  subgraph->inputs = {0};
  subgraph->outputs = {2};
  model.subgraphs.push_back(std::move(subgraph));

  if (spec.with_external_buffers) {
    auto unnamed = std::make_unique<tflite::ExternalBufferGroupT>();
    auto weights = std::make_unique<tflite::ExternalBufferGroupT>();
    weights->name = spec.group_name;
    model.external_buffer_groups.push_back(std::move(unnamed));
    model.external_buffer_groups.push_back(std::move(weights));

    auto first = std::make_unique<tflite::ExternalBufferT>();
    first->id = 1;
    first->group = 1;
    first->offset = 0;
    first->length = 64;
    first->packing = "unpacked";
    auto second = std::make_unique<tflite::ExternalBufferT>();
    second->id = 2;
    second->group = 1;
    second->offset = spec.second_offset;
    second->length = 32;
    second->packing = "unpacked";
    model.external_buffers.push_back(std::move(first));
    model.external_buffers.push_back(std::move(second));
  }

  flatbuffers::FlatBufferBuilder builder;
  tflite::FinishModelBuffer(builder, tflite::Model::Pack(builder, &model));
  return std::vector<uint8_t>(builder.GetBufferPointer(),
                              builder.GetBufferPointer() + builder.GetSize());
}

TEST(ExternalWeightsByPathTest, RewritesGroupNameAndShiftsEveryOffset) {
  const std::vector<uint8_t> bytes = BuildModel({});
  const tflite::Model* before = tflite::GetModel(bytes.data());
  // The case an in-place patch cannot handle: no offset field to write into.
  ASSERT_FALSE(reinterpret_cast<const flatbuffers::Table*>(
                   before->external_buffers()->Get(0))
                   ->CheckField(tflite::ExternalBuffer::VT_OFFSET));

  auto rewritten = RewriteToPath(bytes, kWeightsGroupName, kPath,
                                 kSectionBegin, kSectionSize);
  ASSERT_TRUE(rewritten.ok()) << rewritten.status();
  ASSERT_TRUE(rewritten->has_value());
  auto& buffer = **rewritten;
  ASSERT_TRUE(tflite::ModelBufferHasIdentifier(buffer.Data()));
  flatbuffers::Verifier verifier(buffer.Data(), buffer.Size());
  ASSERT_TRUE(tflite::VerifyModelBuffer(verifier));

  const tflite::Model* after = tflite::GetModel(buffer.Data());
  ASSERT_EQ(after->external_buffer_groups()->size(), 2);
  EXPECT_EQ(after->external_buffer_groups()->Get(0)->name(), nullptr);
  EXPECT_EQ(after->external_buffer_groups()->Get(1)->name()->str(), kPath);
  ASSERT_EQ(after->external_buffers()->size(), 2);
  const tflite::ExternalBuffer* first = after->external_buffers()->Get(0);
  const tflite::ExternalBuffer* second = after->external_buffers()->Get(1);
  EXPECT_EQ(first->id(), 1);
  EXPECT_EQ(first->group(), 1);
  EXPECT_EQ(first->offset(), kSectionBegin);
  EXPECT_EQ(first->length(), 64);
  EXPECT_EQ(first->packing()->str(), "unpacked");
  EXPECT_EQ(second->id(), 2);
  EXPECT_EQ(second->offset(), kSectionBegin + 128);
  EXPECT_EQ(second->length(), 32);

  const tflite::SubGraph* subgraph = after->subgraphs()->Get(0);
  ASSERT_EQ(subgraph->tensors()->size(), 3);
  EXPECT_EQ(subgraph->tensors()->Get(1)->external_buffer(), 1);
  EXPECT_EQ(subgraph->tensors()->Get(2)->external_buffer(), 2);
  EXPECT_EQ(subgraph->tensors()->Get(0)->buffer(), 1);
  const auto* data = after->buffers()->Get(1)->data();
  ASSERT_NE(data, nullptr);
  EXPECT_THAT(std::vector<uint8_t>(data->begin(), data->end()),
              testing::ElementsAre(1, 2, 3, 4, 5, 6, 7, 8));
}

TEST(ExternalWeightsByPathTest, RefusesAppendedBufferData) {
  const std::vector<uint8_t> bytes = BuildModel({.appended_buffer = true});
  auto rewritten = RewriteToPath(bytes, kWeightsGroupName, kPath,
                                 kSectionBegin, kSectionSize);
  EXPECT_EQ(rewritten.status().code(), absl::StatusCode::kFailedPrecondition)
      << rewritten.status();
}

TEST(ExternalWeightsByPathTest, LeavesModelsThatDoNotReadTheSection) {
  // No external buffers at all.
  auto none = RewriteToPath(BuildModel({.with_external_buffers = false}),
                            kWeightsGroupName, kPath, kSectionBegin,
                            kSectionSize);
  ASSERT_TRUE(none.ok()) << none.status();
  EXPECT_FALSE(none->has_value());

  // External buffers, but in a group the section does not back.
  auto other = RewriteToPath(BuildModel({.group_name = "other_weights"}),
                             kWeightsGroupName, kPath, kSectionBegin,
                             kSectionSize);
  ASSERT_TRUE(other.ok()) << other.status();
  EXPECT_FALSE(other->has_value());
}

TEST(ExternalWeightsByPathTest, RefusesAnOffsetOutsideTheSection) {
  // 4080 + 32 > 4096.
  auto rewritten =
      RewriteToPath(BuildModel({.second_offset = kSectionSize - 16}),
                    kWeightsGroupName, kPath, kSectionBegin, kSectionSize);
  EXPECT_EQ(rewritten.status().code(), absl::StatusCode::kInvalidArgument)
      << rewritten.status();
}

TEST(ExternalWeightsByPathTest, RefusesBytesThatAreNotAModel) {
  const std::vector<uint8_t> garbage(64, 0xab);
  auto rewritten = RewriteToPath(garbage, kWeightsGroupName, kPath,
                                 kSectionBegin, kSectionSize);
  EXPECT_EQ(rewritten.status().code(), absl::StatusCode::kInvalidArgument);
}

#if !defined(_WIN32)
TEST(ExternalWeightsByPathTest, AbsolutePathOpensTheSameFile) {
  const std::string file = testing::TempDir() + "/bundle_path_test.bin";
  { std::ofstream(file) << "weights"; }
  auto opened = ScopedFile::Open(file);
  ASSERT_TRUE(opened.ok()) << opened.status();
  auto path = AbsolutePathOf(*opened);
  ASSERT_TRUE(path.ok()) << path.status();
  EXPECT_EQ(path->path.front(), '/');
#if defined(__linux__)
  EXPECT_EQ(path->path.rfind("/proc/self/fd/", 0), 0) << path->path;
  EXPECT_TRUE(path->keep_alive.IsValid());
#endif
  std::ifstream reread(path->path);
  std::string content;
  reread >> content;
  EXPECT_EQ(content, "weights");
}
#endif

}  // namespace
}  // namespace litert::lm::external_weights_by_path
