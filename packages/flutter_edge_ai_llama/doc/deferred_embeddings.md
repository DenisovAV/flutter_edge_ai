# GGUF embedding contribution

Text embeddings now live in this engine package through `LlamaEmbeddingBackend`;
see [design, prerequisites and qualification](embeddings.md). This replaces the
older proposal for a separate GGUF embedding package, matching the LiteRT and
ONNX engine-owned embedding backends.

Image/audio and Web embedding qualification remain separate follow-ups. Runtime
artifacts stay owned by llamadart; core and RAG keep their existing ownership.
