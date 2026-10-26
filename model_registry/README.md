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
| `snapshots/<package>.json` | where each variant runs on each host, as the package answers | the package's catalog test |
| `published/<package>/<version>.json` | the frozen fields a release shipped | the release |
| `hosts.yaml` | the platforms the website shows a status for, in its column order | hand |
| `documented_claims.yaml` | what the docs and release notes say works, with the source | hand |
| `evidence/<date>_<host>_<device>.json` | what a recorded integration run passed, and on which native build | `registry.dart evidence` |

Generated from it, checked in, never edited by hand:
- `packages/flutter_edge_ai_litertlm/lib/src/catalog/generated/litert_catalog.g.dart`:
  `LiteRtLmModels` and `LiteRtEmbedders`, a class per model with a getter
  per variant (`LiteRtLmModels.gemma4E2bIt.npuSm8750`). A variant withheld
  from a release is left out.
- `packages/flutter_edge_ai_speech/lib/src/catalog/generated/speech_catalog.g.dart`:
  `LiteRtSpeechModels`, speech-to-text and text-to-speech in one namespace
  (`LiteRtSpeechModels.moonshineTiny.f32`). A TTS bundle's files are in the
  order of `TtsModelType.manifest`; the package's test checks that core
  fetches each of them from its pinned URL.
- `website/content/docs/registry.md` (the site's Model Registry page) and
  `website/web/models.json` (the same data): every variant, and on every
  host and backend one status:

  | Status | From |
  |---|---|
  | verified | a run under `evidence/` on the native build the packages ship now |
  | stale | the same, on an earlier native build or minor version |
  | documented | a claim in `documented_claims.yaml` |
  | untested | the package's snapshot runs it there and nothing says more |
  | refused | the snapshot does not run it there: a native backend the package rules out, or an NPU build on its vendor's platform |
  | broken | `withhold`, `withhold_backends`, or a broken claim, with its issue |

  A combination that does not exist (an NPU build on another vendor's
  platform, a web export on a phone, a native build on the web) has no cell.

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

## Evidence

The integration tests that the release runs print one line per check that
passed, naming the registry build by the sha256 of the file they installed
(`packages/flutter_edge_ai/example/integration_test/registry_evidence.dart`):

```
FEA_EVIDENCE v2 {"variant":"gemma-4-e2b-it/generic","host":"macos_arm64","backend":"gpu","check":"text"}
```

`backend` is the backend that ran the check's part of the model: for a
`vision` or `audio` check the encoder's own (Gemma 4's audio encoder runs on
the CPU in a GPU run). v1 lines recorded the text model's backend there, so
`evidence` refuses them, and a `schema_version: 1` evidence file counts no
`vision` or `audio` check. The vision and audio checks assert what the
bundled fixtures hold and record nothing for a staged file of unknown content.

Today: `litertlm_ffi_test.dart` (Gemma 4 E2B text, vision and audio on CPU
and GPU, and the staged NPU bundle), `embeddinggemma2_test.dart`,
`stt_moonshine_test.dart` and `tts_smoke_test.dart`. Turn a run's log into an
evidence file at the commit that ran, then generate:

```sh
cd packages/flutter_edge_ai/example
flutter test integration_test/litertlm_ffi_test.dart -d macos 2>&1 | tee /tmp/run.log
cd ../../../tool/model_registry
dart run bin/registry.dart evidence --device "MacBook Pro M4 Pro" /tmp/run.log
dart run bin/registry.dart generate
```

A run is one host. The file records the commit, the package versions, the log's
sha256 (and `--log-url` when the log is published) and the native build: the
sha256 of the host's archive in `flutter_edge_ai_litertlm/hook/build.dart`, or
on the web the litertlm version. A cell is verified while that is still the
build the packages ship and the variant's package is on the same minor
version; after either moves it is stale until the next run. `evidence` refuses
a log from more than one host or from a simulator, uncommitted changes under
`packages/*/lib`, `hook` or `native`, and a cell the package's snapshot does
not run there.

## Check

```sh
cd tool/model_registry
dart run bin/registry.dart generate   # write the generated files
dart run bin/registry.dart check      # validate; fail on a stale one
dart test
```

The Dart names come from the ids: words join in lowerCamelCase, and a word
that starts with a digit after a digit is kept apart with `_`
(`gemma-4-e2b-it` is `gemma4E2bIt`, `qwen3-0.6b` is `qwen3_0_6b`).

After a registry change that moves where a variant runs, write the snapshot
again:

```sh
cd packages/flutter_edge_ai_litertlm
UPDATE_GOLDENS=1 flutter test test/catalog/litert_catalog_test.dart
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
- an id or slug whose Dart name is not an identifier, is a reserved word, or
  clashes;
- a generated file that is not what `generate` writes;
- a frozen field changed after a release, or a published variant deleted;
- a claim on a variant, host or backend that does not exist, on a withheld
  variant, or on a cell the package's snapshot does not run;
- an evidence file that is malformed, names an unknown host or variant or a
  withheld one, a cell the package's snapshot does not run, or a cell a broken
  claim says fails;
- a claim whose source is neither `"PR #<n> ..."` nor
  `website/content/docs/<page>.md:<line>` with that line present (quote a
  pull request source: ` #` starts a YAML comment), or a broken claim without
  its issue;
- Cyrillic text.

`dart test` proves each of those rules fails its own fixture, and that this
directory passes.

## Release

`flutter_edge_ai_litertlm` and `flutter_edge_ai_speech` ship catalogs
generated from here. Before either is published:

```sh
cd tool/model_registry
dart run bin/registry.dart freeze flutter_edge_ai_litertlm     # published/<package>/<version>.json
dart run bin/registry.dart release-check flutter_edge_ai_litertlm
```

`freeze` records the frozen fields the version ships, which `check` then holds
every later change to. `release-check` passes when the registry and every
generated file are current, the frozen fields are written, and every cell
`release_critical.yaml` lists for the package is verified: a run under
`evidence/` on the native build the package ships, since that build or the
package's minor version last moved. A patch on the same native build keeps its
evidence. On success `release-check` writes a stamp with the HEAD it passed at
(`tool/model_registry/.dart_tool/release_check/<package>-<version>.ok`).
`.claude/hooks/guard-release-registry.py` refuses `dart pub publish` of either
package unless that stamp is for HEAD and nothing under `model_registry/`,
`tool/model_registry/` or the package has changed since, or the command carries
`RELEASE_SKIP_REGISTRY="<reason>"`. The hook reads the stamp and asks git; it
runs no repository code, which a hook would run before the command is approved.

CI runs `check` and `dart test` on every pull request (`model-registry` in
`.github/workflows/test.yml`). Weekly, `model-registry-live.yml` runs

```sh
HF_TOKEN=<token> dart run bin/registry.dart live
```

which asks Hugging Face for every pinned file: an LFS or Xet file must redirect
with the registry's sha256 and size, a plain git file is fetched and hashed. A
missing file, other bytes at the commit or no answer fails it; a gated
repository the token cannot read is listed as `noAccess`.
