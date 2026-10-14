# Deferred GGUF embeddings

GGUF embeddings are outside this inference contribution. A separate package
should register through core's embedding SPI and qualify embedding models
independently of the chat runtime.

The follow-up must use core 2.3's public embedding pass SPI: extend
`EmbeddingBackendProvider` and return an `EmbeddingPassDescriptor(engineTag:,
factory:, config:, activeBackend:)` from `describe()`. Core builds, hosts, queues
and closes the model; the connector does not own an `EmbeddingModel`. Apps pass
`EmbeddingInput` to `embed`; oversized input must throw
`EmbeddingInputTooLongException`, never silently truncate. Use a self-contained
GGUF spec without an unused tokenizer companion. Give the specific GGUF backend
priority over a catch-all backend and make prefix selection match the model;
EmbeddingGemma prefixes must not be the default for arbitrary GGUF files.

llamadart defaults `embed` and `embedBatch` to L2 normalization. The follow-up
must verify a compatible embedding model's dimensions, finite values, unit norm
and relative semantic similarity, plus overflow, cancellation, close, capability
and backend selection. Chat smoke results do not qualify embeddings.
