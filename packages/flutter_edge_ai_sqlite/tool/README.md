# `flutter_edge_ai_sqlite` — vec0 build & keystone gates

Tooling for the single-engine **sqlite-vec / vec0** RAG store. These scripts
build the custom web wasm and run the two load-bearing proofs the migration
design rests on. Both proofs are **green** (PoC, 2026-06-21) — keep them green.

See the full migration plan: `docs/plans/sqlite_vector_undeprecate.md`.

## The two keystone gates

| Gate | What it proves | How to run |
|------|----------------|------------|
| **Native** (`../test/vec0_text_pk_test.dart`) | the bundled sqlite3 (Native Assets) loads the prebuilt vec0 extension via the static-entrypoint path, and a `vec0(id TEXT PRIMARY KEY, …)` table round-trips a KNN MATCH returning the TEXT id — no JOIN, no rowid bridge | `VEC0_DYLIB=/path/to/vec0.dylib flutter test test/vec0_text_pk_test.dart` |
| **Web** (`verify_web_vec0.mjs`) | a custom `sqlite3.wasm` with sqlite-vec linked in runs vec0 KNN in headless Chromium under COOP/COEP, returning the same TEXT ids | `node tool/verify_web_vec0.mjs` (after building the probe — below) |

If either gate ever goes red, the "TEXT primary key, no JOIN" single-engine
design is no longer valid and must be revisited before shipping.

## Native gate

Download the prebuilt loadable vec0 extension for your platform from
the repository's own
[`native-sqlite-vec-v*`](https://github.com/DenisovAV/flutter_edge_ai/releases) release.
Do NOT take the loadable straight from
[asg017/sqlite-vec](https://github.com/asg017/sqlite-vec/releases): its Apple
slices carry the legacy minimum-OS values this package normalizes, and the
android one is 4 KB-aligned. Normally no override is needed at all — the suites
resolve the library through `test/vec0_locator.dart`
(the `loadable` asset, e.g. `vec0.dylib` / `vec0.so` / `vec0.dll`), then:

```bash
cd packages/flutter_edge_ai_sqlite
VEC0_DYLIB=/path/to/vec0.dylib flutter test test/vec0_text_pk_test.dart
```

## Web gate (build + verify)

The published `sqlite3.wasm` has no vector extension and the browser has no
runtime `load_extension`, so we compile sqlite-vec into the wasm.

**Build the wasm** (writes `sqlite3.wasm` into the given dir):

```bash
# prereqs (one-time): wasi-sdk at $WASI_SDK, binaryen on PATH (brew install binaryen)
WASI_SDK=/path/to/wasi-sdk tool/build_vec0_wasm.sh tool/web_vec0_probe/web
```

`build_vec0_wasm.sh` clones simolus3/sqlite3.dart at a pinned ref, drops in the
sqlite-vec amalgamation + our two C patches (`sqlite_vec_patches/`), splices
three lines into the live upstream `CMakeLists.txt`, and runs the repo's own
WASI-clang + binaryen pipeline.

**The two patches** — minimal, applied over upstream `sqlite3_wasm_build/src/`:

- `os_web.c` — adds `sqlite3_auto_extension(sqlite3_vec_init)` so vec0 is on
  every connection (sqlite-vec is compiled `-DSQLITE_CORE`).
- `getentropy.c` — defines `__imported_wasi_snapshot_preview1_random_get`
  locally (backed by Dart's secure randomness) so sqlite-vec's pulled-in WASI
  `random_get` resolves at link time and **zero WASI imports** remain on the
  reactor-model wasm.

**Compile the probe + verify:**

```bash
cd tool/web_vec0_probe
dart pub get
dart run build_runner build --release -o web:build
cd ../..
node tool/verify_web_vec0.mjs        # → exit 0 + "RESULT=PASS"
```

(Playwright one-time setup: `npm i playwright && npx playwright install chromium`.)

## Why these live in `tool/` and aren't published

`.pubignore` excludes `tool/` from the published package — consumers don't build
the wasm, they get the prebuilt one. The sqlite-vec amalgamation, the generated
`sqlite3.wasm`, and the probe's build output are gitignored (`tool/.gitignore`):
the **recipe** is tracked, the heavy fetched/generated artifacts are not — same
discipline as the gitignored native `prebuilt/` dirs in the litertlm package.
