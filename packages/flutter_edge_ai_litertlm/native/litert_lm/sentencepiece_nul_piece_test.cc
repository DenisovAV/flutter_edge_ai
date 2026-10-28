// flutter_gemma patch (section 17): tests for
// patches/sentencepiece_nul_piece.patch, through LiteRT-LM's own tokenizer.
//
// SentencePiece 0.2.2 refuses any piece that contains a NUL byte, so a
// byte-level BPE vocabulary converted without byte_fallback (Qwen3-0.6B and
// FastVLM-0.5B carry byte 0x00 as piece 188) no longer loads. The patch keeps
// the refusal only where a Darts trie is built over the piece; these tests pin
// both halves.

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "sentencepiece_model.pb.h"  // from @sentencepiece
#include "support/tokenizer/sentencepiece_tokenizer.h"

namespace litert::support {
namespace {

using ::sentencepiece::ModelProto;
using ::sentencepiece::TrainerSpec;
using ::testing::ElementsAre;
using ::testing::HasSubstr;

using PieceType = ModelProto::SentencePiece::Type;

const std::string kNul(1, '\0');

struct Piece {
  std::string text;
  float score;
  PieceType type = ModelProto::SentencePiece::NORMAL;
};

// A model with no normalization, so the pieces below are what the encoder
// sees: ids 0-2 are <unk>, <s>, </s>, then the vocabulary in order.
std::unique_ptr<ModelProto> MakeModel(TrainerSpec::ModelType type,
                                      const std::vector<Piece>& vocabulary) {
  auto model = std::make_unique<ModelProto>();
  auto* trainer = model->mutable_trainer_spec();
  trainer->set_model_type(type);
  trainer->set_byte_fallback(false);
  trainer->set_unk_id(0);
  trainer->set_bos_id(1);
  trainer->set_eos_id(2);
  trainer->set_pad_id(-1);
  auto* normalizer = model->mutable_normalizer_spec();
  normalizer->set_name("identity");
  normalizer->set_add_dummy_prefix(false);
  normalizer->set_remove_extra_whitespaces(false);
  normalizer->set_escape_whitespaces(false);
  auto add = [&](const Piece& piece) {
    auto* sp = model->add_pieces();
    sp->set_piece(piece.text);
    sp->set_score(piece.score);
    sp->set_type(piece.type);
  };
  add({"<unk>", 0, ModelProto::SentencePiece::UNKNOWN});
  add({"<s>", 0, ModelProto::SentencePiece::CONTROL});
  add({"</s>", 0, ModelProto::SentencePiece::CONTROL});
  for (const Piece& piece : vocabulary) add(piece);
  return model;
}

// Shaped like the converted Qwen2 vocabulary: a single-NUL NORMAL piece
// beside ordinary ones, plus merges that do and do not involve it.
std::vector<Piece> BpeVocabulary() {
  return {
      {kNul, -1},          // 3, like piece 188
      {"a", -2},           // 4
      {"b", -3},           // 5
      {"ab", -0.5},        // 6
      {kNul + "a", -0.4},  // 7
  };
}

TEST(SentencePieceNulPieceTest, BpeModelWithNulPieceLoads) {
  auto tokenizer = SentencePieceTokenizer::CreateFromProto(
      MakeModel(TrainerSpec::BPE, BpeVocabulary()));
  ASSERT_TRUE(tokenizer.ok()) << tokenizer.status();
  EXPECT_EQ((*tokenizer)->GetVocabSize(), 8);
}

TEST(SentencePieceNulPieceTest, BpeEncodesWithoutTouchingOtherPieces) {
  auto tokenizer = SentencePieceTokenizer::CreateFromProto(
      MakeModel(TrainerSpec::BPE, BpeVocabulary()));
  ASSERT_TRUE(tokenizer.ok()) << tokenizer.status();
  auto ids = (*tokenizer)->TextToTokenIds("abba");
  ASSERT_TRUE(ids.ok()) << ids.status();
  EXPECT_THAT(*ids, ElementsAre(6, 5, 4));
}

TEST(SentencePieceNulPieceTest, BpeNulPieceRoundTrips) {
  auto tokenizer = SentencePieceTokenizer::CreateFromProto(
      MakeModel(TrainerSpec::BPE, BpeVocabulary()));
  ASSERT_TRUE(tokenizer.ok()) << tokenizer.status();
  auto id = (*tokenizer)->TokenToId(kNul);
  ASSERT_TRUE(id.ok()) << id.status();
  EXPECT_EQ(*id, 3);
  // A NUL in the text is the NUL piece, and merges with its neighbour as any
  // other piece does.
  auto ids = (*tokenizer)->TextToTokenIds(kNul + "ab" + kNul);
  ASSERT_TRUE(ids.ok()) << ids.status();
  EXPECT_THAT(*ids, ElementsAre(7, 5, 3));
  auto text = (*tokenizer)->TokenIdsToText({7, 5, 3}, false);
  ASSERT_TRUE(text.ok()) << text.status();
  EXPECT_EQ(*text, kNul + "ab" + kNul);
}

// Unigram builds a Darts trie over all its pieces, and Darts throws on a NUL
// byte: the load must still fail with a status, as in stock 0.2.2.
TEST(SentencePieceNulPieceTest, UnigramModelWithNulPieceIsRefused) {
  auto tokenizer = SentencePieceTokenizer::CreateFromProto(
      MakeModel(TrainerSpec::UNIGRAM, BpeVocabulary()));
  ASSERT_FALSE(tokenizer.ok());
  EXPECT_THAT(tokenizer.status().message(), HasSubstr("null character"));
}

// USER_DEFINED pieces go into the prefix matcher's Darts trie on every model
// type, BPE included.
TEST(SentencePieceNulPieceTest, BpeUserDefinedNulPieceIsRefused) {
  std::vector<Piece> vocabulary = BpeVocabulary();
  vocabulary[0].type = ModelProto::SentencePiece::USER_DEFINED;
  auto tokenizer = SentencePieceTokenizer::CreateFromProto(
      MakeModel(TrainerSpec::BPE, vocabulary));
  ASSERT_FALSE(tokenizer.ok());
  EXPECT_THAT(tokenizer.status().message(), HasSubstr("null character"));
}

// The same model without the NUL pieces encodes the same way, so the patch
// changes nothing for a vocabulary that never had one.
TEST(SentencePieceNulPieceTest, BpeWithoutNulPieceUnchanged) {
  auto tokenizer = SentencePieceTokenizer::CreateFromProto(
      MakeModel(TrainerSpec::BPE,
                {{"a", -2}, {"b", -3}, {"ab", -0.5}}));
  ASSERT_TRUE(tokenizer.ok()) << tokenizer.status();
  auto ids = (*tokenizer)->TextToTokenIds("abba");
  ASSERT_TRUE(ids.ok()) << ids.status();
  EXPECT_THAT(*ids, ElementsAre(5, 4, 3));
}

}  // namespace
}  // namespace litert::support
