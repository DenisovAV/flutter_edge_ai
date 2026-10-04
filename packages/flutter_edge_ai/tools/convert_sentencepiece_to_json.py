#!/usr/bin/env python3
"""Convert sentencepiece.model to HuggingFace tokenizers JSON format (Unigram).

Output format matches what UnigramTokenizer.swift expects:
  {"model": {"type": "Unigram", "unk_id": N, "vocab": [["token", score], ...], ...}, ...}

Usage:
  pip install -r tools/requirements.txt
  python tools/convert_sentencepiece_to_json.py \
    --input path/to/sentencepiece.model \
    --output tokenizer.json

Verification:
  python tools/convert_sentencepiece_to_json.py \
    --input gecko_sentencepiece.model \
    --output /tmp/gecko_tokenizer.json \
    --verify example/ios/Runner/embeddinggemma_tokenizer.json
"""

import argparse
import json
import sys

import sentencepiece as spm
from sentencepiece import sentencepiece_model_pb2 as sp_pb2


def load_sentencepiece_model(model_path: str) -> sp_pb2.ModelProto:
    """Load a sentencepiece.model file as protobuf."""
    model = sp_pb2.ModelProto()
    with open(model_path, "rb") as f:
        model.ParseFromString(f.read())
    return model


def convert_to_hf_json(model: sp_pb2.ModelProto) -> dict:
    """Convert SentencePiece ModelProto to HuggingFace tokenizers JSON format."""
    vocab = []
    unk_id = 0
    byte_fallback = model.trainer_spec.byte_fallback if model.trainer_spec else False

    for i, piece in enumerate(model.pieces):
        token = piece.piece
        score = float(piece.score)

        if piece.type == sp_pb2.ModelProto.SentencePiece.UNKNOWN:
            unk_id = i

        vocab.append([token, score])

    # Build added_tokens from special tokens
    added_tokens = []
    special_types = {
        sp_pb2.ModelProto.SentencePiece.CONTROL,
        sp_pb2.ModelProto.SentencePiece.UNKNOWN,
    }
    for i, piece in enumerate(model.pieces):
        if piece.type in special_types:
            added_tokens.append({
                "id": i,
                "content": piece.piece,
                "single_word": False,
                "lstrip": False,
                "rstrip": False,
                "normalized": False,
                "special": True,
            })

    result = {
        "version": "1.0",
        "truncation": None,
        "padding": None,
        "added_tokens": added_tokens,
        "normalizer": {
            "type": "Sequence",
            "normalizers": [
                {
                    "type": "Replace",
                    "pattern": {"String": " "},
                    "content": "\u2581",  # ▁ (lower one eighth block)
                },
                {
                    "type": "Prepend",
                    "prepend": "\u2581",
                },
            ],
        },
        "pre_tokenizer": None,
        "post_processor": None,
        "decoder": {
            "type": "Replace",
            "pattern": {"String": "\u2581"},
            "content": " ",
        },
        "model": {
            "type": "Unigram",
            "unk_id": unk_id,
            "vocab": vocab,
            "byte_fallback": byte_fallback,
        },
    }

    return result


def verify_structure(generated: dict, reference_path: str) -> bool:
    """Verify generated JSON has same structure as reference file."""
    with open(reference_path) as f:
        reference = json.load(f)

    ok = True

    # Check top-level keys match
    gen_keys = set(generated.keys())
    ref_keys = set(reference.keys())
    if gen_keys != ref_keys:
        print(f"  Key mismatch: generated={gen_keys}, reference={ref_keys}")
        ok = False
    else:
        print(f"  Top-level keys match: {sorted(gen_keys)}")

    # Check model structure
    gen_model = generated.get("model", {})
    ref_model = reference.get("model", {})

    gen_model_keys = set(gen_model.keys())
    ref_model_keys = set(ref_model.keys())
    if gen_model_keys != ref_model_keys:
        print(f"  Model key mismatch: generated={gen_model_keys}, reference={ref_model_keys}")
        ok = False
    else:
        print(f"  Model keys match: {sorted(gen_model_keys)}")

    # Check vocab format (first entry)
    gen_vocab = gen_model.get("vocab", [])
    ref_vocab = ref_model.get("vocab", [])
    print(f"  Generated vocab size: {len(gen_vocab)}")
    print(f"  Reference vocab size: {len(ref_vocab)}")

    if gen_vocab and ref_vocab:
        gen_entry = gen_vocab[0]
        ref_entry = ref_vocab[0]
        if len(gen_entry) == len(ref_entry) == 2:
            print(f"  Vocab entry format: [str, float] — matches")
        else:
            print(f"  Vocab entry mismatch: gen={gen_entry}, ref={ref_entry}")
            ok = False

    return ok


def main():
    parser = argparse.ArgumentParser(
        description="Convert sentencepiece.model to HuggingFace tokenizers JSON"
    )
    parser.add_argument("--input", required=True, help="Path to sentencepiece.model")
    parser.add_argument("--output", required=True, help="Output path for tokenizer.json")
    parser.add_argument(
        "--verify",
        help="Path to reference tokenizer.json for structure verification",
    )
    args = parser.parse_args()

    print(f"Loading {args.input}...")
    model = load_sentencepiece_model(args.input)

    print(f"Converting to HuggingFace tokenizers JSON format...")
    result = convert_to_hf_json(model)

    vocab_size = len(result["model"]["vocab"])
    unk_id = result["model"]["unk_id"]
    print(f"  Vocab size: {vocab_size}")
    print(f"  UNK ID: {unk_id}")
    print(f"  First 3 tokens: {result['model']['vocab'][:3]}")

    print(f"Writing {args.output}...")
    with open(args.output, "w") as f:
        json.dump(result, f, ensure_ascii=False)

    import os
    size_mb = os.path.getsize(args.output) / 1024 / 1024
    print(f"  File size: {size_mb:.2f} MB")

    if args.verify:
        print(f"\nVerifying structure against {args.verify}...")
        if verify_structure(result, args.verify):
            print("  Structure verification PASSED")
        else:
            print("  Structure verification FAILED")
            sys.exit(1)

    print("\nDone!")


if __name__ == "__main__":
    main()
