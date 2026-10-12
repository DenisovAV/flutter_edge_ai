#!/usr/bin/env bash
# run_downgrade_harness.sh — R5 §6.6 / §9.3 gate 6: the store downgrade
# harness. The train writes image, audio and text stores (sqlite + qdrant);
# the PUBLISHED flutter_edge_ai_rag 1.0.0 + flutter_edge_ai_sqlite 2.0.1 +
# flutter_edge_ai_qdrant 2.0.1 must refuse every image/audio store (empty or
# not, with or without allowLegacyProfileAdoption) and must not rebind one,
# while still opening the text stores; then the train re-reads every store and
# finds it unchanged.
#
# Needs network the first time (hosted packages, the vec0 and qdrant native
# libraries the hooks download). macOS or Linux host.
#
# Usage: tool/rag_store_compat/run_downgrade_harness.sh
# Exit:  0 every step green · non-zero on the first failing step.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/rag_store_compat.XXXXXX")"
export RAG_COMPAT_STORES="$work/stores"
mkdir -p "$RAG_COMPAT_STORES"
echo "==> stores: $RAG_COMPAT_STORES"

step() {
  local dir="$1" file="$2"
  echo "==> $(basename "$dir"): $file"
  (cd "$here/$dir" && flutter pub get >/dev/null && flutter test "$file")
}

step train test/write_train_stores_test.dart
step published test/refuse_train_stores_test.dart
step train test/verify_train_stores_test.dart

echo "==> downgrade harness green (stores kept in $work)"
