# `.litertlm` header fixtures

The first bytes of two real bundles, up to the end of their `LlmMetadata`
section: the 32-byte preamble, the header flatbuffer, zero padding to offset
16384 and the `LlmMetadata` proto. `litertlm_bundle_sampler_test.dart` reads
them as if they were whole bundles; nothing past the section is needed.

| File | Source | Container | Sampler |
|---|---|---|---|
| `qwen3_0_6b_prefix.litertlm` | `litert-community/Qwen3-0.6B`, `Qwen3-0.6B.litertlm` (sha256 `555579ff…`) | 1.5.0 | TOP_P, k 20, p 0.95, temperature 0.6 |
| `gemma3_1b_prefix.litertlm` | `litert-community/Gemma3-1B-IT`, `Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm` | 1.0.0 | none |

To regenerate, cut each bundle at the end offset of its `LlmMetadataProto`
section (16536 and 16498 bytes here):

```bash
head -c 16536 Qwen3-0.6B.litertlm > qwen3_0_6b_prefix.litertlm
```
