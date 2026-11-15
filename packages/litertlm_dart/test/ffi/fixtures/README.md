# `.litertlm` header fixtures

The first bytes of two real bundles, up to the end of their `LlmMetadata`
section: the 32-byte preamble, the header flatbuffer, zero padding to offset
16384 and the `LlmMetadata` proto. `litertlm_bundle_sampler_test.dart` reads
them as if they were whole bundles; nothing past the section is needed.

| File | Source | Container | Sampler |
|---|---|---|---|
| `qwen3_0_6b_prefix.litertlm` | `litert-community/Qwen3-0.6B`, `Qwen3-0.6B.litertlm` (sha256 `555579ff…`) | 1.5.0 | TOP_P, k 20, p 0.95, temperature 0.6 |
| `gemma3_1b_prefix.litertlm` | `litert-community/Gemma3-1B-IT`, `Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm` | 1.0.0 | none |
| `qwen3_0_6b_dynamic_prefix.litertlm` | `litert-community/Qwen3-0.6B`, `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` (sha256 `03e7da1e…`) | 1.6.0 | the only one of the three that declares an output channel (`LlmMetadata.channels`) |

To regenerate, cut each bundle at the end offset of its `LlmMetadataProto`
section (16536, 16498 and 19476 bytes here):

```bash
head -c 16536 Qwen3-0.6B.litertlm > qwen3_0_6b_prefix.litertlm
```

## EmbeddingGemma 2 container headers

The first bytes of the three EmbeddingGemma 2 bundles, cut at their header end
(the uint64 at offset 24): the 32-byte preamble and the header flatbuffer with
the section table, no section data. `litertlm_container_test.dart` reads the
`model_type` of their `TFLiteModel` sections — how the `.litertlm` embedding
pass tells a bundle with an audio encoder (R5 D23).

| File | Source (`litert-community/…`, revision) | Bundle sha256 | Header end |
|---|---|---|---|
| `embeddinggemma2_270m_header.litertlm` | `embeddinggemma-2-text-270m-litert-lm` @ `9be6e8b9`, `embeddinggemma-2-text-270m.litertlm` | `2d079ee2…6fb` | 880 |
| `embeddinggemma2_440m_header.litertlm` | `embeddinggemma-2-text-vision-440m-litert-lm` @ `e301f74d`, `embeddinggemma-2-text-vision-440m.litertlm` | `92dcbea1…2eb0` | 1552 |
| `embeddinggemma2_740m_header.litertlm` | `embeddinggemma-2-740m-litert-lm` @ `24d962e9`, `embeddinggemma-2-740m.litertlm` | `e7a8a220…7f4c` | 2176 |

```bash
head -c 2176 embeddinggemma-2-740m.litertlm > embeddinggemma2_740m_header.litertlm
```

## Activation-type headers

The container header only (preamble and header flatbuffer, no section data) of
two real bundles, to read whether any `TFLiteModel` section declares
`prefer_activation_type`. `litertlm_bundle_activation_test.dart` reads them.

| File | Source | Header end | `prefer_activation_type` |
|---|---|---|---|
| `functiongemma_270m_header.litertlm` | `sasha-denisov/function-gemma-270M-it`, `functiongemma-270M-it.litertlm` (sha256 `680fead1…`) | 368 | none |
| `gemma4_e2b_header.litertlm` | `litert-community/gemma-4-E2B-it-litert-lm`, `gemma-4-E2B-it.litertlm` (2026-10-13) | 1872 | on `tf_lite_prefill_decode` and the vision encoder |

```bash
head -c 368 functiongemma-270M-it.litertlm > functiongemma_270m_header.litertlm
```

## Gemma 4 E2B per-SoC headers

The container header only (preamble and header flatbuffer, no section data)
of three public NPU bundles from `litert-community/gemma-4-E2B-it-litert-lm`
@ `b3ca0d2f`, fetched with an HTTP range request.
`test/bundle/litertlm_bundle_info_test.dart` reads their sections, declared
backends and `tf_lite_aux`; the compiler stamps live inside the sections and
are tested on synthetic containers.

| File | Source file (LFS sha256) | Header end | What it shows |
|---|---|---|---|
| `gemma4_e2b_qualcomm_sm8750_header.litertlm` | `gemma-4-E2B-it_qualcomm_sm8750.litertlm` (`41dd675f…`) | 1520 | no `backend_constraint` anywhere; `tf_lite_aux` |
| `gemma4_e2b_qualcomm_qcs8275_header.litertlm` | `gemma-4-E2B-it_qualcomm_qcs8275.litertlm` (`ebc103e5…`) | 1616 | text `npu`, audio and vision adapter `cpu`; `tf_lite_aux` |
| `gemma4_e2b_google_tensor_g5_header.litertlm` | `gemma-4-E2B-it_Google_Tensor_G5.litertlm` (`af108298…`) | 1736 | an MTP drafter; `tf_lite_aux` |

Read from the full files over HTTP (2026-10-15): the SM8750 and QCS8275
bundles stamp only `tf_lite_prefill_decode` and `tf_lite_aux`
(`Qualcomm`/`SM8750`, `Qualcomm`/`QCS8275`), so their encoders are not
compiled for the NPU; the Tensor G5 bundle stamps the text model, the MTP
drafter and both encoders (`Google`/`Tensor_G5`).

```bash
curl -sL -r 0-1519 https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it_qualcomm_sm8750.litertlm > gemma4_e2b_qualcomm_sm8750_header.litertlm
```
