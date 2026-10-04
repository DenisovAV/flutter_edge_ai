#!/usr/bin/env bash
# Build + deploy the flutter_edge_ai website to Firebase Hosting.
#
# Ships two artifacts on one hosting site:
#   /  + /docs/*  + /codelabs -> Jaspr static site (this package); the Jaspr
#                                route owns codelabs/index.html (the catalogue)
#   /try/...                  -> the Flutter web example app (live demo)
#   /codelabs/<id>/...        -> Google Codelabs (claat static export)
#
# Usage:  ./deploy.sh            (build both + deploy)
#         ./deploy.sh --no-example   (skip rebuilding the example app)
set -euo pipefail

WEBSITE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXAMPLE_DIR="$WEBSITE_DIR/../packages/flutter_edge_ai/example"
DOMAIN="https://flutteredge.ai"
PROJECT="aichat-c0c27"
TARGET="flutteredgeai"

cd "$WEBSITE_DIR"

# Free jaspr's dev ports so the build's transient server can bind.
for p in 5567 8080 8181 5467; do
  lsof -ti ":$p" 2>/dev/null | xargs kill -9 2>/dev/null || true
done

echo "==> Building Jaspr site (SSG)…"
# Wipe stale incremental build state first. A reused .dart_tool/build cache let
# the static crawler snapshot `/` before the ContentApp route table registered,
# producing a 3-byte `Ok` index.html (and zero docs routes) that then got
# deployed. A clean rebuild is cheap and removes the failure mode entirely.
rm -rf build/jaspr .dart_tool/build
jaspr build --sitemap-domain "$DOMAIN"

if [[ "${1:-}" != "--no-example" ]]; then
  echo "==> Building Flutter web example app (base-href /try/)…"
  ( cd "$EXAMPLE_DIR" && flutter build web --release --base-href /try/ )
fi

echo "==> Assembling /try into the Jaspr build output…"
rm -rf build/jaspr/try
mkdir -p build/jaspr/try
cp -R "$EXAMPLE_DIR/build/web/." build/jaspr/try/

# Codelab sources live under website/codelabs/<id>/index.md. Each is claat-exported
# to self-contained HTML under /codelabs/<id>/ and served as STATIC — not rendered
# through Jaspr, so the bash/yaml/xml code fences that break Jaspr's CodeBlock
# grammar are fine here. Runs after the `rm -rf build/jaspr` wipe above, and
# after `jaspr build` wrote the catalogue at codelabs/index.html — claat only
# ever writes into codelabs/<id>/, so the two never collide.
#
# The export itself lives in tool/export_codelabs.sh, shared with
# .github/workflows/firebase-hosting-merge.yml. It also repoints the element
# library at our vendored copy, blanks claat's default Google Analytics id and
# adds the codelabs to sitemap.xml — see that file for why each is needed.
CLAAT="$(command -v claat || echo "$HOME/.local/bin/claat")"
if [[ -x "$CLAAT" ]]; then
  CLAAT="$CLAAT" DOMAIN="$DOMAIN" tool/export_codelabs.sh
elif [[ "${SKIP_CODELABS:-}" == "1" ]]; then
  echo "    WARNING: claat missing and SKIP_CODELABS=1 — this deploy REMOVES the live /codelabs (404)."
else
  # Fail closed: build/jaspr was already wiped above, so continuing to
  # `firebase deploy` would delete the live /codelabs. CI has no such escape
  # hatch; the human-run path must not be the fail-open one.
  echo "ERROR: claat not found; deploying now would DELETE the live /codelabs (404)." >&2
  echo "Install claat-darwin-amd64 from https://github.com/googlecodelabs/tools/releases" >&2
  echo "into ~/.local/bin/claat (chmod +x), or re-run with SKIP_CODELABS=1 to deploy without codelabs." >&2
  exit 1
fi

echo "==> Deploying to Firebase Hosting ($TARGET)…"
firebase deploy --only "hosting:$TARGET" --project "$PROJECT"

echo "==> Done. https://flutteredge.ai (https://flutteredge-ai.web.app)  (demo at /try, codelabs at /codelabs)"
