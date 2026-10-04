## 0.5.2
- Require `flutter_edge_ai` 2.x.

## 0.5.1
- Renamed from `flutter_gemma_onnx`.
- Fix web text generation failing with `NoSuchMethodError` on every call.
- Web setup pins `onnxruntime-web` 1.30.0 and Transformers.js 4.3.0.

## 0.5.0
- Native inference `activeBackend` reports null instead of echoing the requested backend.

## 0.4.0
- No longer depends on `flutter_gemma_embeddings`; asks core for a tokenizer, so register `embeddingTokenizers:`.

## 0.3.3
- Prefer `pooler_output` over `last_hidden_state`; re-index corpora from any graph exposing both.
- Refuse a SigLIP2 `tokenizer.json` instead of embedding it with Gemma's convention.
- Require `flutter_gemma_embeddings` 2.1.0, which fixes `flutter build web` for the web embedding arm.

## 0.3.2
- `OnnxHuggingFaceResolver` installs an ORT-GenAI model directory from a Hugging Face repo — lists the repo, picks a CPU execution-provider folder, downloads the whole bundle (#454).

## 0.3.1
- Fix a rebuilt native library not reaching the build.
- Fail the build on an unusable runtime — a failed download, a checksum mismatch, or an Android minSdk below 24 — instead of bundling nothing.

## 0.3.0

- Add web text generation via Transformers.js (`@huggingface/transformers`) — `OnnxEngine` web arm (WebGPU/WASM, HF-repo-id models).
- Fix iOS embeddings: probe ORT `GetApi` down from v27 (the ORT inside onnxruntime-genai predates 1.27).
- Fix Windows embeddings: pass the model path to `OrtCreateSession` as UTF-16 (`ORTCHAR_T` is `wchar_t` on Windows).
- Device-verify embeddings on macOS + Linux + Windows + Android + iOS (unified `onnx_embedding_device_test`).

## 0.2.0

- Add web support for `OnnxEmbeddingBackend` via onnxruntime-web (WebGPU/WASM, WordPiece models).
- `OnnxEngine` (text generation) declines on web for now — Transformers.js support is a fast-follow.

## 0.1.0

- Initial release: `OnnxEngine` — ORT-GenAI text generation over `dart:ffi`, macOS/Linux/Windows/Android/iOS arm64.
- Add `OnnxEmbeddingBackend`: plain ONNX Runtime embedding forward pass over `dart:ffi` (no ORT GenAI).
- Fix ORT/GenAI co-location via `ORT_LIB_PATH` (dladdr) — no Podfile/packaging step needed.
- Harden `GenAiFfiClient` lifecycle: cancel/stop/close races can no longer wedge the mutex or hang a caller.
- Platform-gate both engines to macOS/Linux/Windows/Android arm64 + iOS arm64; other hosts fail loud, not with a confusing native error.
- Add `OrtClient`/`OrtFfiClient`: injectable ORT 1.27.0 C API seam, fake-testable with zero dlopen.
- Verified against real all-MiniLM-L6-v2 (WordPiece) and EmbeddingGemma-300M-ONNX (SentencePiece) models on macOS.
