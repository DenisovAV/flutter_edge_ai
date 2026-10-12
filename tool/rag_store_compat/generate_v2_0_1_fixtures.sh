#!/usr/bin/env bash
# generate_v2_0_1_fixtures.sh — writes the text-bound v2_0_1 store fixtures
# with the PUBLISHED flutter_edge_ai_rag 1.0.0 + flutter_edge_ai_sqlite 2.0.1 +
# flutter_edge_ai_qdrant 2.0.1 (R5 §6.6) and copies them into
#   packages/flutter_edge_ai_sqlite/test/fixtures/v2_0_1/text_store.db
#   packages/flutter_edge_ai_qdrant/test/fixtures/v2_0_1/text_store.tar.gz
# The committed fixtures were generated once; run this only to replace them,
# and review the fixture tests' pinned profile and documents if you change
# what it writes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/rag_store_fixtures.XXXXXX")"

(cd "$here/published" && flutter pub get >/dev/null &&
  RAG_COMPAT_OUT="$out" flutter test test/generate_v2_0_1_fixtures_test.dart)

cp "$out/sqlite/text_store.db" \
  "$repo/packages/flutter_edge_ai_sqlite/test/fixtures/v2_0_1/text_store.db"
# A tarball: qdrant preallocates 32 MB WAL and storage files of zeros.
(cd "$out/qdrant" && COPYFILE_DISABLE=1 tar -czf "$out/text_store.tar.gz" text_store)
cp "$out/text_store.tar.gz" \
  "$repo/packages/flutter_edge_ai_qdrant/test/fixtures/v2_0_1/text_store.tar.gz"
echo "==> fixtures written (sources kept in $out)"
