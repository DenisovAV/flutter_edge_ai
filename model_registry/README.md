# Model registry

The models this project offers, one file per model, each pinned to the exact
Hugging Face files it installs. The example app, the packages' generated
catalogs and the website's model lists are generated from it, so a model is
added or changed here and nowhere else.

Scope today: the LiteRT family. Every `.litertlm` (LLMs and EmbeddingGemma 2)
and every `.tflite` (EmbeddingGemma 1 and Gecko embedders, speech-to-text,
text-to-speech) in the repositories below. The schema already admits `task`,
`gguf`, `onnx` and `builtIn` files; their catalogs come later.

## Layout

| Path | What | Written by |
|---|---|---|
| `models/<id>.yaml` | a model and its variants | hand |
| `derived/<sha256>.json` | facts read from a file's bytes | `inspect_bundle_test.dart` |
| `published/<package>/<version>.json` | the frozen fields a release shipped | the release |

## An entry

```yaml
id: gemma-4-e2b-it            # the file name; lowercase words joined by - or .
kind: llm                     # llm | embedder | stt | tts
package: flutter_edge_ai_litertlm
display_name: Gemma 4 E2B
family: gemma4                # open string: the site's secondary filter
arch_class: matformer-ple     # open string: dense, vision-language, encoder, ...
license: apache-2.0
license_url: https://www.apache.org/licenses/LICENSE-2.0
model_type: gemma4            # llm only: core ModelType
capabilities: {image: true, audio: true, function_calls: true, thinking: true}
runtime: {max_tokens: 4096, preferred_backend: gpu}
variants:
- slug: npu-sm8750            # unique in the model; the variant id is <id>/<slug>
  file_type: litertlm
  file:
    repo: litert-community/gemma-4-E2B-it-litert-lm
    revision: b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1   # a commit, never main
    path: gemma-4-E2B-it_qualcomm_sm8750.litertlm
    sha256: 41dd675f...       # the LFS oid at that revision
    size: 3016294400
    install_filename: gemma-4-E2B-it_qualcomm_sm8750.litertlm
  npu: {vendor: qualcomm, soc: SM8750}   # as the compiler stamped it
  fixed_max_tokens: 4096      # the KV-cache length the build is compiled for
  runtime: {preferred_backend: npu}
  example: [gemma4_E2B_litertlm]   # the example enum values that install it
```

Per kind:

- **llm**: `model_type`, `capabilities` and `runtime` on the model. A variant
  may override `capabilities` and `runtime`, and a web bundle sets
  `web_bundle: true`.
- **embedder**: `modalities` on the model. A variant has `rag_profile_id`
  (and `image_rag_profile_id` when the model embeds images), `dimension` and
  `max_input_tokens`. A `.tflite` variant also has a `tokenizer` artifact; a
  `.litertlm` one carries its own. An NPU variant has
  `preferred_backend: npu`.
- **stt**: `stt_type` on the model; each variant has a `file` and a
  `tokenizer`.
- **tts**: `tts_type` on the model; its one variant lists `files`, in the
  order of `TtsModelType.manifest` in core.

Optional on any variant:
- `withhold: {reason, issue}` keeps it out of what the package offers.
- `withhold_backends: {gpu: {reason, issue}}` does the same for one backend.
- `deprecated: {reason, use}`.

`gated: auto | manual` on an artifact is the repository's Hugging Face gating.

## Frozen fields

Once a release ships a variant, these never change for its id:
- `install_filename`: an installed model is found by it;
- `sha256`;
- `rag_profile_id` and `image_rag_profile_id`: a stored index is bound to them.

Changing one strands what users already have.

New bytes mean a new variant, with a new slug, a new install file name and,
for an embedder, a new profile id. Then deprecate the old variant. A variant
added to an existing family follows the family's pattern:
- file names: `<stem>__rev-<12 hex of the revision>`;
- EmbeddingGemma 2 profile ids: `-npu-<soc>`, and `-vis140` for the image
  tower.

## Facts read from the bytes

The `npu` target, `fixed_max_tokens` and the container format are read from the
file, not taken from its name. File names on Hugging Face follow no single
pattern, and once a file named `tensor_g6` held a Tensor G5 build.

```sh
cd packages/flutter_edge_ai_litertlm
INSPECT_FILES=<json list of {sha256, url, size}> \
INSPECT_OUT=../../model_registry/derived \
HF_TOKEN=<token, for gated repositories> \
  flutter test test/catalog/inspect_bundle_test.dart
```

It runs the package's own readers over HTTP range requests (a few hundred
kilobytes per file) and writes `derived/<sha256>.json` for each file:
- the compiler's NPU stamp;
- for a `.litertlm`, also its sections, `LlmMetadata.max_num_tokens` and the
  KV-cache length of its decode graph.

## Check

```sh
cd tool/model_registry
dart run bin/registry.dart check
dart test
```

`check` fails on:
- an unknown key or a missing required one;
- a revision that is not a 40-hex commit, or any Hugging Face URL that
  resolves `main`;
- a duplicate id or slug;
- an NPU LLM build without `fixed_max_tokens`;
- an NPU target or compiled context that the bytes contradict;
- a `.litertlm` or NPU file that was never read;
- a native file that is not a LiteRT-LM container;
- one install file name for two different files;
- one profile id with two dimensions;
- a withheld variant without an issue;
- a frozen field changed after a release, or a published variant deleted;
- Cyrillic text.

`dart test` proves each of those rules fails its own fixture, and that this
directory passes.
