# Deferred GGUF embeddings

GGUF embeddings are outside this inference contribution. The original provider,
tests and model qualification are preserved at commit
`a4b84603f1ba6dfc5a10ebde9360c246915424e7` in this branch's history.

The follow-up must implement the new public embedding pass SPI from core PR
#635, letting core own model hosting, queues and lifecycle. Use a self-contained
GGUF spec without an unused tokenizer companion. Give the specific GGUF backend
priority over a catch-all backend and make prefix selection match the model;
EmbeddingGemma prefixes must not be the default for arbitrary GGUF files.

Published llamadart 0.11.1 defaults `embed` and `embedBatch` to L2 normalization.
The preserved BGE real-model test checks 384 dimensions, finite values, unit norm
and relative semantic similarity. Carry that assertion into the follow-up,
along with overflow, cancellation, close, capability and backend-selection tests.
Historical embedding evidence in the platform matrix belongs to that preserved
revision and does not describe the current inference package.
