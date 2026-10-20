#!/usr/bin/env bash
# Runs a Multimodal RAG clip on a Snapdragon 8 Elite Gen 5 (SM8850) phone — for
# example one in Qualcomm Device Cloud, reached over an adb tunnel — with
# EmbeddingGemma 2 (740M) and Gemma 4 E2B compiled for its NPU, and records
# the screen.
#
#   integration_test/tools/multimodal_rag_qdc.sh push            # once per phone
#   integration_test/tools/multimodal_rag_qdc.sh <clip> [device] # search|ask|askvoice|live|retrieval
#
# Files (EMBEDDER, LLM, GOLDEN override where they are read from on this Mac):
#   embeddinggemma-2-740m_Qualcomm_SM8850.litertlm   559448064 bytes
#     https://huggingface.co/litert-community/embeddinggemma-2-740m-litert-lm
#     (catalog entry embeddingGemma2TextVisionAudio740mSm8850, SHA-256 pinned)
#   gemma4_2b_SM8850_towers.litertlm                2918406772 bytes
#     Gemma 4 E2B for the SM8850: text on the Hexagon NPU, vision and audio
#     towers on the CPU. Not on Hugging Face; not in the catalog, so the run
#     passes its backend (npu) and context (1024: an NPU bundle has one
#     compiled cache length, and the NPU is never clamped).
#   knowledge_vectors_cpu_740m.json                    342699 bytes
#     the CPU 740M's vector for every sample item (knowledge_retrieval_test
#     with MULTIMODAL_RAG_VECTORS_OUT on macOS), for the NPU parity numbers.
# all into /data/local/tmp/knowledge/. At ~1 MB/s through a tunnel the push is
# about an hour: do it before the session's clock matters. The app is the
# example as built here (qualcomm_npu: true), installed by `flutter test`.
#
# The recording: `screenrecord` stops at 180 s, so it runs in back-to-back
# segments for as long as the test runs; each segment's start is logged (the
# phone's clock, the one the app's `[clip] <epoch ms>` lines use) in
# <out>/segments.txt. The first run also builds and installs the app (a few
# minutes over a slow tunnel): record the second.

set -uo pipefail

CLIP=${1:?usage: multimodal_rag_qdc.sh push|search|ask|askvoice|live|retrieval [device]}
DEVICE=${2:-}
ADB=(adb ${DEVICE:+-s "$DEVICE"})
REMOTE=/data/local/tmp/knowledge
EMBEDDER=${EMBEDDER:-$HOME/models/knowledge/npu/embeddinggemma-2-740m_Qualcomm_SM8850.litertlm}
LLM=${LLM:-$HOME/Downloads/gemma4_2b_SM8850_towers.litertlm}
GOLDEN=${GOLDEN:-$HOME/models/knowledge/npu/knowledge_vectors_cpu_740m.json}
OUT=${OUT:-$PWD/knowledge-qdc-$(date +%Y%m%d-%H%M%S)}
EXAMPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

push() {
  "${ADB[@]}" shell mkdir -p "$REMOTE"
  for file in "$EMBEDDER" "$LLM" "$GOLDEN"; do
    local name size remote_size
    name=$(basename "$file")
    size=$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file")
    remote_size=$("${ADB[@]}" shell stat -c %s "$REMOTE/$name" 2>/dev/null | tr -d '\r')
    if [[ "$remote_size" == "$size" ]]; then
      echo "== $name already there ($size bytes)"
      continue
    fi
    echo "== pushing $name ($size bytes)"
    "${ADB[@]}" push "$file" "$REMOTE/$name" || exit 1
  done
  "${ADB[@]}" shell ls -l "$REMOTE"
}

if [[ "$CLIP" == push ]]; then
  push
  exit 0
fi

SOC=$("${ADB[@]}" shell getprop ro.soc.model | tr -d '\r')
echo "== phone: $("${ADB[@]}" shell getprop ro.product.model | tr -d '\r'), SoC $SOC"
[[ "$SOC" == SM8850* ]] || echo "!! not an SM8850: the NPU bundles will be refused"

mkdir -p "$OUT"
DEFINES=(
  --dart-define=MULTIMODAL_RAG_EMBEDDER_MODEL=embeddingGemma2TextVisionAudio740mSm8850
  "--dart-define=MULTIMODAL_RAG_EMBEDDER_FILE=$REMOTE/$(basename "$EMBEDDER")"
)
if [[ "$CLIP" == retrieval ]]; then
  TEST=integration_test/knowledge_retrieval_test.dart
  DEFINES+=("--dart-define=MULTIMODAL_RAG_VECTORS_GOLDEN=$REMOTE/$(basename "$GOLDEN")")
else
  TEST=integration_test/multimodal_rag_clips_test.dart
  DEFINES+=(
    "--dart-define=MULTIMODAL_RAG_CLIP=$CLIP"
    "--dart-define=MULTIMODAL_RAG_LLM_FILE=$REMOTE/$(basename "$LLM")"
    --dart-define=MULTIMODAL_RAG_LLM_BACKEND=npu
    --dart-define=MULTIMODAL_RAG_LLM_MAX_TOKENS=1024
  )
  # ENCODERS=npu for a build whose vision and audio encoders are compiled for
  # the NPU too (Google's all-NPU Gemma 4 E2B); unset keeps them on the CPU.
  if [[ -n "${ENCODERS:-}" ]]; then
    DEFINES+=("--dart-define=MULTIMODAL_RAG_LLM_ENCODERS=$ENCODERS")
  fi
fi

# Back-to-back screen recording while the test runs.
record() {
  local n=0
  while [[ ! -f "$OUT/.done" ]]; do
    echo "$n $("${ADB[@]}" shell date +%s | tr -d '\r')000" >>"$OUT/segments.txt"
    "${ADB[@]}" shell screenrecord --time-limit 180 --bit-rate 8000000 \
      "/sdcard/knowledge-$CLIP-$n.mp4"
    n=$((n + 1))
  done
}
rm -f "$OUT/.done"
record &
RECORDER=$!

echo "== flutter test $TEST (log: $OUT/$CLIP.log)"
(cd "$EXAMPLE" && flutter test "$TEST" ${DEVICE:+-d "$DEVICE"} "${DEFINES[@]}") \
  2>&1 | tee "$OUT/$CLIP.log"
STATUS=${PIPESTATUS[0]}

touch "$OUT/.done"
"${ADB[@]}" shell pkill -INT screenrecord >/dev/null 2>&1
wait "$RECORDER"
for remote in $("${ADB[@]}" shell ls "/sdcard/knowledge-$CLIP-*.mp4" | tr -d '\r'); do
  "${ADB[@]}" pull "$remote" "$OUT/" >/dev/null && "${ADB[@]}" shell rm "$remote"
done
grep -E '\[(clip|Multimodal RAG|knowledge)\]' "$OUT/$CLIP.log" >"$OUT/$CLIP-markers.txt"
echo "== $OUT:"
find "$OUT" -maxdepth 1 -type f -print
exit "$STATUS"
