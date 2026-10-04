# Benchmark: `flutter_edge_ai_sqlite` (sqlite-vec / vec0) vs `flutter_edge_ai_qdrant`

> **Status: measured on macOS arm64 for 1k and 10k corpora.** The tables below
> contain the completed run. The optional 100k corpus remains a follow-up.

## Why this benchmark exists

`flutter_edge_ai_sqlite` moved KNN out of Dart and into SQLite (C, via
`sqlite-vec`'s `vec0` virtual table). The old store did brute-force / in-memory
`local_hnsw` search **in Dart**; that path is deleted. This benchmark has two
jobs:

1. **Confirm the deprecation reason is gone.** sqlite was slow only because KNN
   ran in Dart. With KNN now in C inside SQLite, the gap to qdrant should
   collapse.
2. **Measure the qdrant advantage honestly.** The earlier **"~75× faster"**
   claim was measured against the deleted Dart brute-force / HNSW code, not
   vec0. This run established the current **~5–11×** headline used by
   `flutter_edge_ai_qdrant` documentation.

   qdrant is expected to stay the fastest **native** option (HNSW ANN vs vec0's
   exact brute-force `MATCH`, especially at large N); the goal is to stop
   overstating sqlite's gap, not to dethrone qdrant.

## Harness

`packages/flutter_edge_ai_sqlite/tool/bench_vector_stores.dart` — a pure-Dart,
host-VM, loop-runnable benchmark. It runs **one deterministic corpus + query
set** (fixed seed, fixed dimension) through **both** stores behind the identical
`VectorStoreRepository` API, so the input is byte-identical across stores. It
prints a parseable markdown table (the three tables shown below) and exits
non-zero if the correctness gate fails.

On SDKs whose plain `dart run` FFI kernel transformer can't compile the
transitive `sqlite3` `NativeCallable` (observed on Dart 3.12.0 here — `dart run`
and `dart compile exe` both crash with *"type 'InvalidType' is not a subtype of
type 'FunctionType'"*), drive it through the Flutter test toolchain instead,
which compiles the same imports cleanly:
`packages/flutter_edge_ai_sqlite/test/bench_vector_stores_test.dart` calls the
same `runBench()`.

### Methodology (deterministic, loop-runnable)

- **Corpus.** Each document `doc-i` gets a deterministic, L2-normalised
  embedding from a fixed-seed PRNG keyed on its index (Box–Muller Gaussian over
  the unit sphere), plus a tiny JSON metadata blob `{"idx":i}`. Same seed →
  same vectors for every store and every run.
- **Dimension.** 384 by default (a real embedder size; e.g. all-MiniLM-L6-v2).
- **Distance.** cosine on both stores (vec0 `distance_metric=cosine`; qdrant
  `Distance.cosine`). vec0 returns distance → the store converts
  `similarity = 1 - distance`; qdrant returns cosine score in `[-1, 1]`
  directly. Both surface the same `RetrievalResult.similarity` contract.
- **Queries.** Reuse corpus embeddings at evenly spaced indices, so each query
  has a known exact nearest neighbour (id == that index) — deterministic, and a
  real top-1 rather than noise.
- **Measurements (per store, per corpus size, per topK):**
  - **`addDocument` throughput** — docs/sec for the bulk insert of the whole
    corpus.
  - **`searchSimilar` latency** — `warmup` searches discarded, then
    `repeats × queries` timed searches; report **median** and **p90** in µs.
    The median search latency is the headline "75×" number.
- **Corpus sizes.** **1k and 10k by default.** 100k is **off by default** (slow
  + memory-heavy on the exact-KNN arm) — opt in with
  `--sizes=1000,10000,100000`.
- **topK.** 5 and 50.
- **Correctness gate.** For every query, the two stores must return the **same
  top-K id set** (within float tolerance at the similarity layer). A
  fast-but-wrong store is a fail; the harness exits 1 on any mismatch. The gate
  only runs when **both** arms are available.

### Defaults

| Knob | Default | Flag |
|------|--------:|------|
| Corpus sizes | `1000, 10000` (100k off) | `--sizes=1000,10000,100000` |
| topK | `5, 50` | `--topks=5,50` |
| Dimension | `384` | `--dim=384` |
| Search repeats | `11` (odd → exact median) | `--repeats=11` |
| Warm-up searches | `3` | `--warmup=3` |
| Queries / measurement | `20` | `--queries=20` |
| PRNG seed | `1234567` | `--seed=1234567` |
| Parity tolerance | `1e-4` | `--tol=1e-4` |
| Skip qdrant arm | off | `--no-qdrant` |
| Skip vec0 arm | off | `--no-vec0` |

## How to run

You need **both** native extensions present, on the **host architecture**:

- **vec0** — a prebuilt `sqlite-vec` loadable extension
  (github.com/asg017/sqlite-vec/releases), pointed at by `$VEC0_DYLIB`.
- **qdrant-edge** — nothing to supply. Since `flutter_edge_ai_qdrant` 1.3.0 the
  engine ships with the official `qdrant_edge` SDK and its Native Assets hook,
  which `flutter test` runs. `$QDRANT_DYLIB` survives only as the opt-in switch
  that unskips the benchmark; its value is not read.

From `packages/flutter_edge_ai_sqlite/`:

```bash
# Canonical runner on the Flutter test toolchain (works where `dart run` crashes
# on the sqlite3 NativeCallable). Defaults: sizes 1k,10k · topK 5,50.
VEC0_DYLIB=/path/to/vec0.dylib \
QDRANT_DYLIB=1 \
flutter test test/bench_vector_stores_test.dart

# Override the matrix via $BENCH_ARGS (same flags as the tool):
VEC0_DYLIB=... QDRANT_DYLIB=... \
BENCH_ARGS="--sizes=1000,10000,100000 --topks=5,50 --repeats=11" \
flutter test test/bench_vector_stores_test.dart

# On an SDK without the NativeCallable kernel regression, the tool runs directly:
VEC0_DYLIB=... QDRANT_DYLIB=... dart run tool/bench_vector_stores.dart
```

If only one extension is available the harness runs that arm and **skips** the
other (the correctness gate is skipped — it needs both). A plain `flutter test`
with neither env var set **skips** the benchmark entirely (it is a tool, not a
CI gate).

---

## Results

- **Date (UTC):** 2026-06-21
- **Platform:** macOS 15.5 (24F74), Apple Silicon arm64
- **Dart:** 3.12.0 (stable)
- **Dimension:** 384 (L2-normalised, cosine)
- **vec0 version:** v0.1.9 · **qdrant-edge version:** 0.7.3
- **Config:** seed 1234567 · queries 20 · repeats 11 · warmup 3

> 100k not run in this pass (1k/10k only); the harness supports
> `--sizes=…,100000` on a machine with the headroom. Numbers are host-VM macOS
> arm64 — relative shape, not absolute device latency.

### addDocument throughput (docs/sec, higher = better)

| Corpus | vec0 | qdrant | speedup (qdrant/vec0) |
|-------:|-----:|-------:|----------------------:|
| 1000   | 2601.5 | 5484.4 | 2.11× |
| 10000  | 2238.0 | 10718.6 | 4.79× |

### searchSimilar latency (median µs, lower = better)

| Corpus | topK | vec0 median | vec0 p90 | qdrant median | qdrant p90 | speedup (vec0/qdrant) |
|-------:|-----:|------------:|---------:|--------------:|-----------:|----------------------:|
| 1000   | 5    | 368.0  | 402.0  | 67.0  | 97.0  | 5.49×  |
| 1000   | 50   | 512.0  | 562.0  | 177.0 | 220.0 | 2.89×  |
| 10000  | 5    | 3422.0 | 5094.0 | 312.5 | 344.0 | 10.95× |
| 10000  | 50   | 3763.0 | 4154.0 | 428.0 | 479.0 | 8.79×  |

### Correctness gate — top-K id parity (0 mismatches = pass)

| Corpus | topK | mismatched queries | verdict |
|-------:|-----:|-------------------:|:--------|
| 1000   | 5    | 0 | PASS |
| 1000   | 50   | 0 | PASS |
| 10000  | 5    | 0 | PASS |
| 10000  | 50   | 0 | PASS |

> **vec0 is exact brute-force KNN by default** — both stores return the same
> top-K id sets (0 mismatches), confirming no encoding or distance-metric drift.
> qdrant's speed advantage is its HNSW ANN index vs vec0's exact `MATCH` scan.

### What this means for the "~75×" claim

The headline finding: qdrant is **~5.5× faster at 1k and ~11× at 10k** than
vec0 on search — **not ~75×**. The old "~75×" was measured against the **deleted
Dart brute-force/HNSW** path; once KNN moved into C (sqlite-vec), the gap
collapsed by roughly an order of magnitude. qdrant remains the fastest **native**
option (and pulls further ahead as N grows, ANN vs exact), but vec0 delivers
**identical top-K results** and is the **only** store that also runs on web — so
the trade-off is speed-at-scale (qdrant) vs portability + exactness (vec0), not
the lopsided gap the "75×" number implied.

---

## Follow-up

Run the optional 100k corpus on a machine with enough memory to measure how the
gap changes at larger scale. Keep vec0 exact by default to preserve its current
semantics; evaluate optional ANN or quantization separately if exact search is
too costly at that size.
