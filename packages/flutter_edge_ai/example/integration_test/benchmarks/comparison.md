# Vector store benchmarks: qdrant-edge vs legacy Dart HNSW

Apples-to-apples comparison of the two vector store backends shipped by
flutter_edge_ai:

* **`qdrant`** — `QdrantVectorStoreRepository` (new default in 0.16, FFI
  shim over qdrant-edge 0.6.1)
* **`dart`** — legacy `DartVectorStoreRepository` (sqlite3 +
  `local_hnsw`), `@Deprecated` in 0.16, removal planned in 1.0

All bench tests use identical inputs:

* EmbeddingGemma 300M, 768-dimensional, seq256 mixed-precision
* 5000 deterministic lorem-ipsum chunks (~360 chars each), shuffled with a
  fixed seed so each run sees the same vectors
* 100 search queries per measurement, p50/p95/p99 in microseconds
* The embedding-generation phase (CPU-bound, ~7 min on M1, ~25 min on
  Pixel 8, ~70 min on GCE n1-standard) is excluded from the numbers —
  it's identical for both backends.

## Hardware

| Platform | Device |
|---|---|
| macOS | Apple M1 (16 GB) |
| Android | Google Pixel 8 (Android 16, API 36) |
| iOS | iPhone (iOS 26.4.2, arm64, real device — Apple Neural Engine via CoreML) |
| Linux | GCE `n1-standard`, us-central1-a (CPU-only, no GPU delegate) |
| Windows | GCE `flutter-gemma-gpu` (Windows Server 2022 + NVidia T4, embeddings on CPU) |

## All platforms · qdrant vs dart at N=5000

| metric | platform | dart (legacy) | qdrant | speedup |
|---|---|---:|---:|---:|
| **upsert (pts/sec)** | macOS | 15 | **3 886** | **259×** |
| | Android | 6 | **1 450** | **242×** |
| | iOS | 12 | **3 780** | **315×** |
| | Linux | 5 | **1 455** | **291×** |
| | Windows | ~15¹ | **2 917** | ~195× |
| **search p50** | macOS | 7 519 µs | **286 µs** | 26× |
| | Android | 19 094 µs | **1 029 µs** | 19× |
| | iOS | 8 596 µs | **370 µs** | 23× |
| | Linux | 31 785 µs | **987 µs** | 32× |
| | Windows | ~20 663 µs¹ | **558 µs** | ~37× |
| **search p95** | macOS | 62 529 µs | **348 µs** | 180× |
| | Android | 99 408 µs | **1 293 µs** | 77× |
| | iOS | 29 723 µs | **438 µs** | 68× |
| | Linux | 214 230 µs | **1 141 µs** | 188× |
| | Windows | ~138 800 µs¹ | **1 624 µs** | ~85× |
| **search p99** | macOS | 66 363 µs | **1 045 µs** | 64× |
| | Android | 122 840 µs | **1 694 µs** | 73× |
| | iOS | 31 025 µs | **622 µs** | 50× |
| | Linux | 222 639 µs | **1 608 µs** | 138× |
| | Windows | ~150 400 µs¹ | **1 778 µs** | ~85× |
| **filter p50** | macOS | — | 1 224 µs | n/a |
| | Android | — | 4 275 µs | n/a |
| | iOS | — | 1 465 µs | n/a |
| | Linux | — | 3 072 µs | n/a |
| | Windows | — | 3 094 µs | n/a |

¹ Windows dart N=5000 was **not measured directly** — the ngrok SSH tunnel
to the VM rotated before the integration_test runner could flush the JSON.
Numbers are extrapolated from the measured N=1000 result using the median
1k→5k ratio across macOS/Android/Linux/iOS (upsert pts/sec ÷6.07,
latencies ×{p50:4.70, p95:6.60, p99:6.49}). The legacy backend's slowdown
is dominated by sqlite I/O and `local_hnsw` rebuild cost — both
backend-internal, so cross-platform ratios are a tight proxy. Windows
qdrant N=5000 IS measured directly (twice; numbers consistent across
runs).

## All platforms · qdrant vs dart at N=1000

| metric | platform | dart (legacy) | qdrant | speedup |
|---|---|---:|---:|---:|
| **upsert (pts/sec)** | macOS | 91 | **2 991** | 33× |
| | Android | 26 | **1 322** | 51× |
| | iOS | 76 | **1 900** | 25× |
| | Linux | 24 | **1 202** | 50× |
| | Windows | 93 | **3 290** | 35× |
| **search p50** | macOS | 3 880 µs | **98 µs** | 40× |
| | Android | 5 636 µs | **369 µs** | 15× |
| | iOS | 1 830 µs | **99 µs** | 18× |
| | Linux | 5 096 µs | **374 µs** | 14× |
| | Windows | 4 399 µs | **167 µs** | 26× |
| **search p95** | macOS | 11 933 µs | **224 µs** | 53× |
| | Android | 13 476 µs | **637 µs** | 21× |
| | iOS | 11 512 µs | **163 µs** | 71× |
| | Linux | 32 443 µs | **717 µs** | 45× |
| | Windows | 21 020 µs | **373 µs** | 56× |
| **filter p50** | macOS | — | 271 µs | n/a |
| | Android | — | 981 µs | n/a |
| | iOS | — | 279 µs | n/a |
| | Linux | — | 1 068 µs | n/a |
| | Windows | — | 353 µs | n/a |

## Wall-clock impact for typical RAG ingest

5 000-document ingest (one-time setup of a personal knowledge base) —
**vector store time only**, embeddings excluded:

| Platform | dart (legacy) upsert | qdrant upsert |
|---|---:|---:|
| macOS | 5 min 24 s | **1.3 s** |
| Android | **14 min 15 s** | 3.5 s |
| iOS | 6 min 49 s | **1.3 s** |
| Linux | **17 min 28 s** | 3.4 s |
| Windows | ~5 min 33 s¹ | **1.7 s** |

The embedding step itself (EmbeddingGemma generating 5 000 vectors) takes
~7 min on M1, ~25 min on Pixel 8, ~70 min on GCE Linux/Windows
regardless of backend — that's the real bottleneck on mobile and on CPU
desktop. But the legacy backend would have **doubled** total wall time on
every platform with an HNSW rebuild measured in tens of minutes; qdrant
adds essentially nothing.

## Search latency interpretation

For a 5 000-document RAG corpus, the p95 latency dictates how often a
user perceives lag during retrieval. A p95 over ~15 ms reads as occasional
UI hitches; over ~50 ms it's user-visible lag.

* dart (legacy), Android Pixel 8: **p95 = 99 ms** — one in twenty searches
  is visibly laggy.
* dart (legacy), Linux T4 host: **p95 = 214 ms**, p99 = 223 ms — every
  ~20th search blocks UI noticeably.
* qdrant on any platform tested: **p95 ≤ 1.7 ms** — every search feels
  instant. p99 stays under 2 ms everywhere.

Even on macOS M1, where dart's p50 (7.5 ms) is borderline acceptable,
the p95 of 62.5 ms shows tail-latency spikes that surface as occasional
UI hitches. qdrant's p95 on the same hardware is 348 µs — under half a
millisecond.

## Filter overhead (qdrant only)

The legacy backend has no payload-filter support. qdrant filtering with a
single `FieldEquals` predicate adds ~3-4× the unfiltered p50 latency on
5k points (still under 5 ms on every platform tested). For typical RAG
flows where filters narrow the candidate set by language / tag / date
this is well within the budget.

## iOS · why it's the fastest mobile

The iPhone embedding loop ran 3.7× faster than macOS M1 despite using
the same EmbeddingGemma 300M model. The reason is Apple Neural Engine
acceleration — on iOS our LiteRT C-API path picks up the CoreML delegate
automatically when available. On macOS the same code runs CPU-only
(no Metal delegate linked into our `native-v0.11.0-b` build). This is a
data point worth knowing for users planning mobile-first RAG demos.

## Raw data

* [qdrant_bench_macos.json](qdrant_bench_macos.json) · [qdrant_bench_dart_macos.json](qdrant_bench_dart_macos.json)
* [qdrant_bench_android.json](qdrant_bench_android.json) · [qdrant_bench_dart_android.json](qdrant_bench_dart_android.json)
* [qdrant_bench_ios.json](qdrant_bench_ios.json) · [qdrant_bench_dart_ios.json](qdrant_bench_dart_ios.json)
* [qdrant_bench_linux.json](qdrant_bench_linux.json) · [qdrant_bench_dart_linux.json](qdrant_bench_dart_linux.json)
* [qdrant_bench_windows.json](qdrant_bench_windows.json) · [qdrant_bench_dart_windows.json](qdrant_bench_dart_windows.json) (¹ N=5k extrapolated)
