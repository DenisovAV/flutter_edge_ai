# flutter_edge_ai_litertlm

> **Renamed from [`flutter_gemma_litertlm`](https://pub.dev/packages/flutter_gemma_litertlm).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_litertlm/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

LiteRT-LM on-device engine for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai):
runs `.litertlm` models and LiteRT `.tflite` embeddings. Opt-in package — add it
only if you run either. Android, iOS, macOS, Linux and Windows via `dart:ffi`;
Web (early preview) via `@litert-lm/core` and LiteRT.js.

This package **owns** the shared LiteRT-LM native library (`libLiteRtLm`) and
exposes the LiteRt interpreter FFI (`LiteRtBindings`); both are shared by
[flutter_edge_ai_speech](https://pub.dev/packages/flutter_edge_ai_speech). As of
1.5.0 this package also ships the LiteRT C API embedding backend
(`LiteRtEmbeddingBackend`) — see [Embeddings](#embeddings) below — over the
runtime-agnostic embedding pipeline in `flutter_edge_ai`. Tokenizers come from
[flutter_edge_ai_embeddings](https://pub.dev/packages/flutter_edge_ai_embeddings),
which the app registers; this package does not depend on it.

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-inference`, covers the `.litertlm` engine, installing a model from Hugging Face, sessions, streaming, and the platform setup for all six targets.

## Usage

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
);
```

`LiteRtLmEngine` handles `ModelFileType.litertlm` models; pass it alongside
other engines (e.g. `MediaPipeEngine` from `flutter_edge_ai_mediapipe`) if your app
uses both formats.

## Install from a Hugging Face repo (`litertlm_manifest.json`)

Repos that ship a
[`litertlm_manifest.json`](https://github.com/john-rocky/hf-to-litertlm/blob/main/manifest/SCHEMA.md)
deployment manifest describe every `.litertlm` file they contain — which
backends each is verified on, which file a given platform should pick, sha256/
size identity, and session guidance. `LitertlmManifestResolver` reads it so an
app installs "the right file for this device" without hardcoding filenames:

```dart
import 'dart:math' show max;

// LiteRtLmEngine carries this resolver, so registering the engine registers
// it too. Pass huggingFaceResolvers: only to override — e.g.
// [LitertlmManifestResolver(revision: 'abc123')] to pin a commit.
await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);

final r = await FlutterEdgeAi.resolveHuggingFace(
    'litert-community/Qwen3-4B-Thinking-2507',
    fileType: ModelFileType.litertlm);
await FlutterEdgeAi.installModel(
      // The manifest types 2507 as qwen3; ModelType.qwen is right for it.
      // For other repos, r.modelType ?? ModelType.general.
      modelType: ModelType.qwen,
      fileType: r.fileType,
    )
    .fromNetwork(r.url) // authoritative: carries the resolver's revision pin
    .install();
final model = await FlutterEdgeAi.getActiveModel(defaults: r.runtime);
final session = await model.createSession(
  enableThinking: r.runtime.thinkingDeclared ?? false,
  // minOutputTokens is a floor, not a cap: keep the app's own budget unless
  // the manifest asks for more.
  maxOutputTokens: max(1024, r.runtime.minOutputTokens ?? 0),
);
```

Everything the manifest returns is an overridable default (explicit argument >
manifest > SDK default); `r.notes` carries platform caveats and known issues
worth surfacing to developers. Repos without a manifest keep working through
`installModel(...).fromHuggingFace(repo, file: ...)`.

To resolve and install in one step, omit `file`: `fromHuggingFace(repo)` reads
the manifest at install time, installs the revision-pinned variant, and returns
the same defaults on `InferenceInstallation.runtime` (plus `notes`). The
two-step form above stays the offline-safe one — manifest mode needs the network
on every install, because the variant's filename is only known after the fetch.

## Embeddings

```dart
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],
);
```

Both lists, and both packages: this one brings the backend, and
`flutter_edge_ai_embeddings` brings the tokenizers it asks core for. On web the
tokenizer list is unused — the LiteRT.js bundle tokenizes in JS.

`LiteRtEmbeddingBackend` runs Gecko / EmbeddingGemma `.tflite` models via the
LiteRT C API. The pipeline it plugs into — the forward-pass seam, the worker
isolate and the pooling — lives in `flutter_edge_ai`; the tokenizers come from
`flutter_edge_ai_embeddings`, which your app registers via
`embeddingTokenizers:`. This package depends on neither beyond core.
On web it runs via LiteRT.js instead; see
[Embeddings on web](#embeddings-on-web) below for the four files and the
`<script>` tag your app needs.

`EmbeddingModel.activeBackend` is `cpu` on native, the only backend this
package's embedder uses, so `preferredBackend` is not applied. On web it is
`null` and LiteRT.js picks: `window.getLiteRtEmbeddingAccelerator()` names where
the output buffer lived after the first embedding, and
`window.getLiteRtEmbeddingFullyAccelerated()` says whether the graph landed
entirely on the requested accelerator — `false` also when LiteRT silently
recompiled a WebGPU request for WASM.

## Embeddings on web

On web, `flutter_edge_ai_litertlm`'s embedding backend runs via LiteRT.js. Copy
all four files from this package's `web/` into your app's `web/`, next to
`index.html` — `litert_embeddings.js` imports the other three by relative path,
so they have to sit together:

```
litert_embeddings.js  sentencepiece.js  litert.js  tensorflow.js
```

They are four pieces of one bundle (the entry plus three vendor chunks), built
together by `tool/web_build`, so never mix them across package versions. Find
this package's directory with
`grep -A1 '"name": "flutter_edge_ai_litertlm"' .dart_tool/package_config.json`,
then load the entry module from `web/index.html`:

```html
<script type="module" src="litert_embeddings.js"></script>
```

Upgrading from an earlier version: delete the copies in your app's `web/` and
re-copy all four from this package. Before 1.8.0 they came from
`flutter_edge_ai_embeddings`, and the copies you have are built against an older
`@litertjs/core` than the runtime this version loads. If you built your own
`web/wasm/`, either delete it and take the CDN default or rebuild it from the
version in `LiteRtWebRuntime.pinnedVersion`.

> Loading `litert_embeddings.js` straight from a CDN with a
> Subresource-Integrity hash — which an older README suggested — cannot work:
> the module's three imports resolve against the CDN path, where they do not
> exist, so the module never executes and every embedding call fails on an
> undefined global. SRI would not have covered the imports either.

### The WASM runtime

LiteRT.js loads a WASM runtime at the first embedding call —
`litert_wasm_internal.js`, or `litert_wasm_compat_internal.js` on a browser
without relaxed SIMD, each with a ~9 MB `.wasm` beside it. Since 1.8.0 they come
from the pinned `@litertjs/core` build on jsDelivr by default — nothing to
install, and nothing this package has to carry into every native-only app.

To serve them yourself (offline, an air-gapped deploy, or a CSP that forbids
third-party script), copy `node_modules/@litertjs/core/wasm/` into your app's
`web/wasm/` and point the package at it before the first embedding:

```dart
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

LiteRtWebRuntime.wasmPath = '/wasm/';
```

Those files come from `@litertjs/core` — `npm i @litertjs/core@2.5.3` in a
scratch directory, then copy its `wasm/`.

Set the prefix before the first embedding — the runtime is loaded once and
cached, so a later assignment is ignored. LiteRT.js inserts the separator when
it joins the prefix with the file name, so the trailing slash above is
convention, not a requirement; the value is root-absolute, and an app served
under a base href other than `/` needs `/my-app/wasm/` or a full URL.

Pin `@litertjs/core` to `LiteRtWebRuntime.pinnedVersion` if you vendor it. The
runtime and this package's `web/litert.js` are two halves of one release —
`litert.js` calls that release's WASM entry points by name — and a mismatch
fails at the first embedding with something that does not mention versions at
all: a runtime older than the glue gives
`Cannot read properties of undefined (reading 'create')`.

Serving it yourself is also the answer if a third-party script in your app's
runtime path is not acceptable to you: LiteRT.js injects the `<script>` itself,
so the CDN copy carries no Subresource-Integrity hash.

Whatever host you use must send `Access-Control-Allow-Origin` (LiteRT.js sets
`crossOrigin="anonymous"` on the script it injects) and serve `.wasm` as
`application/wasm`.

Native platforms need no setup — the LiteRT native library is bundled at build
time by `flutter_edge_ai_litertlm`'s Native-Assets hook.

## Web setup (early preview)

`.litertlm` web inference runs via `@litert-lm/core` (WebGPU/WASM, text-only).
`createSession(maxOutputTokens:)` is honoured here as it is on native. Earlier
releases of this package accepted the argument and logged that it was ignored.
Add the handshake below to your app's `web/index.html` `<head>` — the ESM doesn't
assign window globals and module scripts are deferred, so Dart awaits
`window.litertLmReady` (which resolves to the `Engine` constructor):

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.17.1/+esm');
  window.Engine = m.Engine;
  return m.Engine;
})();
</script>
```

Native platforms need no web setup.

## Platforms

| Platform | Support |
|----------|---------|
| Android  | ✅ FFI (GPU via OpenCL, NPU on Qualcomm — opt-in, below) |
| iOS      | ✅ FFI (GPU via Metal on device; CPU on simulator) |
| macOS / Linux | ✅ FFI (GPU via Metal / Vulkan; NPU on Qualcomm Linux arm64 — opt-in, below) |
| Windows  | ✅ FFI (CPU + GPU via DirectX 12 + Intel NPU) |
| Web      | ✅ via `@litert-lm/core` (CDN, early preview) |

`PreferredBackend.npu` is attempted only on Windows, on Android devices with
Qualcomm FastRPC (`libcdsprpc.so`) and on Qualcomm Linux arm64 boards, the last
two when the app opted in (below); elsewhere it falls back to GPU, then CPU, and
prints why. On Windows the check is per OS, so
a PC without an Intel NPU can report `activeBackend == npu` while the model runs
elsewhere.

### Qualcomm NPU on Android and Linux arm64 (opt-in)

This package does not ship Qualcomm's QNN runtime: Qualcomm licenses it for
redistribution inside an application only. To use `PreferredBackend.npu` on
Snapdragon, opt in from your app's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

Put it in the pubspec of the app you build. If that app is a member of a pub
workspace, put it in the workspace root's pubspec instead; pub ignores
`user_defines` anywhere else.

With the flag set, the build hook downloads `com.qualcomm.qti:qnn-runtime:2.50.0`
from Maven Central once, checks its SHA-256, raises the Hexagon libraries'
page alignment to the 16 KB Google Play requires, and bundles the ten QNN
libraries into the Android app: about 22 MB more to download and 83 MB more
installed (one blob per Hexagon generation, V73 to V81). The first NPU run
copies them out of the APK once more, because the DSP loads them from files,
so a phone that uses the NPU holds about 166 MB of them. Setting the
flag means accepting Qualcomm's AI Stack License, the `LICENSE.pdf` the hook
prints the path of. Its notices are in this package's `NOTICES`, so they reach
your app's licence page.

Behind a proxy, the hook honours `HTTPS_PROXY`. Without access to Maven Central,
point it at a mirror or at the AAR itself:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
      qualcomm_npu_maven_url: https://maven.example.com/maven2
      # or: qualcomm_npu_aar: third_party/qnn-runtime-2.50.0.aar
```

`qualcomm_npu_aar` is resolved against the pubspec that declares it and must be
the same file as Maven's (same SHA-256). Without the flag, a request for
`PreferredBackend.npu` on Android falls back to GPU, then CPU, and the log says
how to enable it.

**Linux arm64.** The same flag bundles the stack into Linux arm64 builds, for
Qualcomm Linux boards with a Hexagon V68–V81 compute DSP (QCS6490, QCS8275,
QCS9075, …). Qualcomm publishes no Maven artifact for Linux, so the hook reads
the fourteen libraries it needs (libQnnHtp, libQnnSystem and a Stub/Skel pair
per Hexagon version) out of Qualcomm's public QAIRT 2.50 SDK zip with HTTP range
requests — about 32 MB of a 2.6 GB archive — checks each against a pinned
SHA-256, and caches them; about 90 MB more installed. Offline, download
`v2.50.0.260828.zip` yourself and point the hook at it:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
      qualcomm_npu_qairt_zip: third_party/v2.50.0.260828.zip
```

On the board, Qualcomm's FastRPC library must be installed (`qcom-fastrpc1` on
Ubuntu; Qualcomm's images ship it) and the user must be in group `fastrpc`
(`sudo usermod -aG fastrpc $USER`, then log in again). If either is missing,
`npu` falls back to GPU, then CPU, and the log names what to fix. Use the model
compiled for your SoC, e.g. `gemma-4-E2B-it_qualcomm_qcs8275.litertlm`. A Linux
x64 build ignores the flag.

The native library is fetched at build time by `hook/build.dart` (Native Assets)
from a SHA256-verified GitHub release — no manual setup on native platforms.

## Troubleshooting

### Qwen keeps reasoning with thinking off, or shows `<|channel>thought` text (fixed in 1.9.0)

Up to 1.8.7 "thinking off" sent nothing to the template, and a Qwen3 template
that reads `enable_thinking` treats a missing key as on: a bundle such as
`Qwen3-0.6B_dynamic` spent its whole output budget reasoning. Bundles that
declare a thought channel also streamed that reasoning into the answer as
`<|channel>thought…<channel|>` text, and the web path sent `thinking` — a key no
template reads. 1.9.0 sends `enable_thinking` both ways on every platform, and
`flutter_edge_ai` 2.1.0 turns channel reasoning into `ThinkingResponse` for every
`ModelType` and no longer appends ` /no_think` to an audio message (Qwen3-ASR
returned an empty transcript).

### A stopped chat answers every later message with nothing (fixed in 1.8.1)

Symptom: after `stopGeneration()` in the middle of a reply — or after
abandoning the response stream — every later message on that chat or session
comes back empty, on Android, iOS and desktop. A new chat on the same model
answers normally. (The web engine is a separate path and is not covered by this
entry.)

Cause: a conversation whose generation is cancelled mid-reply stays unusable
in the native runtime.

Fix: upgrade to 1.8.1. The first turn after a stop now runs on a fresh
conversation that replays the chat's history, including whatever the stopped
reply had produced. That history is replayed as text: images and audio sent in
earlier turns are not, so after a stop the model can no longer see them.

### Google Play rejects the app over 16 KB page sizes (fixed in `flutter_gemma_litertlm` 1.8.0)

Symptom: Play Console refuses the release with *"Your app does not support
16 KB memory page sizes"*, on any app that depends on this package. Nothing
fails at build or run time — the rejection happens at submission.

Cause: the Qualcomm Hexagon DSP blobs of the NPU path
(`libQnnHtpV{73,75,79,81}Skel.so`) arrive from Qualcomm with a 4 KB `p_align`.
Before 1.10.0 this package bundled them into every APK; Play scans
`lib/**/*.so` and does not care that a Hexagon image is loaded by the DSP
rather than mapped by the kernel.

Fix: every `flutter_edge_ai_litertlm` release has it. Since 1.10.0 the Skels
ship only when the app sets `qualcomm_npu: true`, and the hook raises them to
16 KB. Check your own build with Google's `check_elf_alignment.sh` against the
APK, not against this package.

### Android GPU crashes at engine_create on Mali (fixed in 1.8.2)

Symptom: in 1.7.0–1.8.1, `PreferredBackend.gpu` on an Android phone with a Mali
GPU (Samsung A-series, MediaTek, Google Tensor) kills the process while the
model loads — `SIGSEGV` at `pc 0` inside `libLiteRtOpenClAccelerator.so`. The
CPU backend and Adreno GPUs are unaffected.

Cause: the OpenCL and GPU accelerators from LiteRT-LM v0.17.0 call
`AHardwareBuffer_allocate` without declaring `libandroid.so` as a dependency, so
Android binds the call to address 0. Only Mali takes that path.

Fix: upgrade to 1.8.2 (`native-v0.17.1-a`). No app change is needed. See
[#545](https://github.com/DenisovAV/flutter_edge_ai/issues/545).

### Any tool call kills the app (fixed in 1.7.1)

Symptom: in 1.7.0, a chat or session created with `tools` dies on the first
decoded token — `EXC_BAD_ACCESS` / `SIGSEGV` inside the runtime, on every
platform, CPU and GPU alike. Dart sees no exception; `flutter test` reports only
that the test did not complete. Generation without tools is unaffected.

Cause: constrained decoding is implemented by a prebuilt companion,
`libGemmaModelConstraintProvider`, that ships with the LiteRT-LM release.
Upstream replaced the `Constraint` interface, and the companion published at tag
v0.17.0 still implements the old one, so the runtime we build calls into the
wrong vtable slot.

Fix: upgrade to 1.7.1, which pins the native bundle `native-v0.17.0-a` — the same
runtime with the companion rebuilt from upstream main. FunctionGemma also needs
`flutter_gemma` 1.8.4: 1.7.1 sends the tool result as a role-`tool` message, and
core decides that it should.

### Windows: embeddings or speech fail with `status=3` (fixed in 1.7.0)

Symptom: on Windows only, `LiteRtEmbeddingBackend` and `flutter_edge_ai_speech`
fail with `LiteRT call failed: CreateTensorBufferFromHostMemory(...) (status=3)`
in 1.4.0–1.6.4. Text generation is unaffected.

Cause: LiteRT made `LiteRtLayout` one layout on every compiler; this package
still wrote tensor shapes in the old MSVC layout on Windows.

Every `flutter_edge_ai_litertlm` release includes the fix. On the legacy package
line, upgrade `flutter_gemma_litertlm` to 1.7.0 and `flutter_gemma_speech` to
0.5.1.

### Garbled or empty streams on Android (fixed in 1.5.2)

Symptom: a generation delivers zero chunks and throws
`Exception: Stream error: <U+FFFD>`, often followed by
`Callback invoked after it has been deleted` and a `SIGABRT` that Dart cannot
catch.

Cause: on Android the first `dlopen` of `libLiteRtLm` decides, for the whole
process, whether its exports are reachable from the default symbol search
scope, and bionic never promotes an already-loaded library afterwards. Before
1.5.2 the embeddings and speech entry point opened it locally, so an app that
embedded or transcribed anything before its first generation left the
stream-callback ABI probe unable to see the library — and the probe read that
as "old library" and registered the wrong callback shape.

Fix: upgrade to 1.5.2. If you load `libLiteRtLm` yourself from app or
third-party code, load it before flutter_edge_ai does and with `RTLD_GLOBAL`.
1.5.2 cannot repair that case — bionic never promotes an already-loaded library
— but it no longer generates corrupt text: a `.litertlm` generation raises a
`StateError` naming the condition, and embeddings or speech (which resolve
through their own handle and do not need the symbols to be ambient) log a
warning and carry on.
See [#447](https://github.com/DenisovAV/flutter_edge_ai/issues/447).

### `dlopen` / "library not found" (`libLiteRtLm`)

`flutter_edge_ai_litertlm` is the sole owner of the shared native library
(`libLiteRtLm`) and bundles it via its build hook — this package's own
`LiteRtEmbeddingBackend` and `flutter_edge_ai_speech` both use it directly. A
stale Native-Assets cache after a
native version bump can leave the library unbundled, surfacing as an opaque
`dlopen` "no such file" on the first inference. Fix with a clean rebuild:

```bash
flutter clean
rm -rf ~/Library/Caches/flutter_gemma/native        # macOS
rm -rf ~/.cache/flutter_gemma/native                # Linux
# Windows: rmdir /s "%LOCALAPPDATA%\flutter_gemma\native"  (path may vary)
flutter pub get
```
