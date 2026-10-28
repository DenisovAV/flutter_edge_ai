# Platform setup for flutter_edge_ai

Entries each platform needs before a model will load. Without them the app
builds and then fails at model load, or is killed for memory.

- [Android](#android)
- [iOS](#ios)
- [macOS](#macos)
- [Windows and Linux](#windows-and-linux)
- [Web](#web)

## Android

`android/app/build.gradle.kts` (or `build.gradle`):

```
android {
    defaultConfig {
        minSdk = 30
    }
}
```

`minSdk 30` covers everything built on `.litertlm`: inference, embeddings and
speech. On API 29 the native library fails to load at runtime — the build does
not catch it. MediaPipe `.task` models run on lower API levels.

`android/app/src/main/AndroidManifest.xml` needs the internet permission to
download a model. Flutter's template declares it only for debug and profile
builds, so without this line the release build cannot download:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

Only `arm64-v8a` is shipped for `.litertlm`. The OpenCL manifest entries the GPU
backend needs are merged in by the plugin; nothing to add.

`PreferredBackend.npu` on Snapdragon is opt-in (`flutter_edge_ai_litertlm`
1.10.0+): Qualcomm licenses its QNN runtime for redistribution inside an app
only, so the app's own `pubspec.yaml` asks for it — the workspace root's, if
the app is a pub workspace member:

```yaml
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

The build hook then fetches `com.qualcomm.qti:qnn-runtime` from Maven Central
and bundles it (about 83 MB installed). Without the flag, a bundle compiled for
an NPU (`…_qualcomm_sm8750.litertlm`) runs on the NPU only and is refused with
the reason: a `BackendInitException` whose one attempt is an
`NpuDispatchUnavailableException` naming the flag. A generic bundle never runs
on the NPU, flag or not: `npu` falls back to GPU, then CPU, for it.

Google Tensor takes its own flag in the same block, `google_tensor_npu: true`:
the build then bundles the Tensor dispatch (built from LiteRT; the runtime,
`libedgetpu_litert.so`, is part of the Pixel system image). A
`…_Google_Tensor_G5.litertlm` or `…_Google_Tensor_G6.litertlm` bundle runs on a
Pixel with that Tensor generation and Android 16 or later, not a BP2A build. A
device outside that rule, or an app without the flag, is refused before any
engine (a `BackendInitException` naming why); a Pixel of the other Tensor
generation is refused by LiteRT when the engine is created. It never moves to
the GPU or the CPU. Run so far on Tensor G6 Pixels with
debug builds: Gemma 4 E2B text, images and audio, EmbeddingGemma 2 270m and
440m.

MediaTek takes `mediatek_npu: true` in the same `flutter_edge_ai_litertlm` block (`flutter_edge_ai_litertlm` 1.17.0): the
build fetches Google's `litert-npu-runtime-mediatek` AAR from Google Maven and
bundles its dispatch (about 330 KB); the NeuroPilot runtime it drives is part of
the phone. A bundle compiled for a MediaTek SoC (Google publishes Gemma 3 1B,
Gemma 3 270M, Qwen3 0.6B and EmbeddingGemma 2 ones; no Gemma 4) runs on a phone
with that SoC and Android 12 or later whose vendor exposes NeuroPilot to apps;
any other device is refused before any engine, a bundle for another SoC when
the engine is created, and it never moves to the GPU or the CPU. Offline:
`mediatek_npu_aar: <path>`. Run on a Galaxy Tab S10+ (Dimensity 9300+, MT6989,
Android 16) with a debug build: Gemma 3 1B (`…_mt6989`) generates on the NPU;
MT6991/MT6993 bundles are refused there.

## iOS

Minimum iOS 15.0 — 16.0 if the app includes `flutter_edge_ai_mediapipe`, 16.4
with `flutter_edge_ai_llama`.

With CocoaPods, in `ios/Podfile`, declared once:

```ruby
platform :ios, '15.0'   # '16.0' if the app includes flutter_edge_ai_mediapipe
use_frameworks! :linkage => :static
```

With Swift Package Manager — the default since Flutter 3.44 — there is no
Podfile. Set **iOS Deployment Target** on the Runner target in Xcode instead, or
the build fails with `requires minimum platform version 15.0`.
`flutter_edge_ai_mediapipe` has no `Package.swift`, so an app using it gets a
Podfile as well; set the platform there too.

In Xcode, under **Signing & Capabilities**, add **Extended Virtual Addressing**,
**Increased Memory Limit** and **Increased Debugging Memory Limit**. That writes
these keys to `ios/Runner/Runner.entitlements` and links the file to the target
— a file edited by hand but not linked does nothing. Without them large models
are killed for memory:

```xml
<key>com.apple.developer.kernel.extended-virtual-addressing</key>
<true/>
<key>com.apple.developer.kernel.increased-memory-limit</key>
<true/>
<key>com.apple.developer.kernel.increased-debugging-memory-limit</key>
<true/>
```

The iOS Simulator runs only on an Apple Silicon Mac (`arm64`; no Intel `x86_64`
simulator build) and cannot run GPU inference; use CPU there, or a real device.

## macOS

Apple Silicon (`arm64`) only: there is no native library for Intel (`x86_64`)
Macs. The deployment target must be **macOS 14.0**: set Minimum Deployments on
the Runner target in Xcode (`MACOSX_DEPLOYMENT_TARGET = 14.0`), and
`platform :osx, '14.0'` in `macos/Podfile` if the app has one. LiteRT-LM's
companion libraries are built for macOS 14; below it the build fails with
`requires minimum platform version 14.0` (Swift Package Manager) or `required a
higher minimum deployment target` (CocoaPods).

Add to both `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

`network.client` lets the sandboxed app download the model. Add it to both
files — the debug and release builds read different ones.

Do not copy the iOS `com.apple.developer.kernel.*` keys into these files; they
are iOS entitlements. Without a signing team the build fails with `"Runner" has
entitlements that require signing with a development certificate`, and a
team-signed build silently drops them. A `.litertlm` model loads on macOS
without them.

`.litertlm` on macOS also needs two companion libraries in the app
(`GemmaModelConstraintProvider`, `LiteRtLmMetalAccelerator`), which the package
keeps out of Native Assets. How they get there depends on Swift Package Manager:

- **On** (the default since Flutter 3.44), with `flutter_edge_ai_litertlm`
  1.19.0 or later: nothing to add. Its Swift package brings them, and Xcode
  embeds and signs them with the app's identity. This holds when the app also
  has a `macos/Podfile` for another plugin.
- **Off** (`flutter: config: enable-swift-package-manager: false` in
  `pubspec.yaml`): paste the block below into `macos/Podfile`, replacing any
  existing `post_install` block; the next build runs `pod install` itself. Also
  add `com.apple.security.cs.disable-library-validation` to both entitlements
  files: the build phase signs the libraries ad hoc, and under Hardened Runtime
  (which notarization requires) library validation refuses them without it.
  The `flutter_gemma` phase, cache and stamp names in this snippet are
  intentional compatibility identifiers used by the current package; do not
  rename them.

A green build proves nothing: without the libraries the first model load fails
with an error that contains
`flutter_edge_ai_litertlm: LiteRT-LM did not load on macOS` and names the fix.

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)
  end

  # flutter_gemma: stage the upstream Apple companion dylibs into the built
  # .app. `hook/build.dart` deliberately skips them from Native Assets on macOS
  # (#247 — Google ships them without `-Wl,-headerpad_max_install_names`, so the
  # JIT bundling path cannot rewrite their install_name), which leaves this
  # build phase to stage them.
  #
  # The phase only LOCATES and RUNS a script; the staging logic itself lives in
  # flutter_edge_ai_litertlm and is delivered next to the dylibs it stages. That
  # is deliberate: this block is frozen into your Xcode project, and a copy of
  # the logic frozen there cannot be fixed by upgrading the package.
  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.user_targets.each do |user_target|
      phase_name = '[flutter_gemma] Setup LiteRT-LM macOS'

      # Only the app target embeds the Frameworks/ this phase patches.
      # RunnerTests inherits Runner's framework search paths and has no
      # Contents/Frameworks of its own — having the phase there creates a
      # cross-target dependency on Runner's framework output that Xcode reports
      # as "Cycle inside Flutter Assemble" (#300). Remove any stale copy from
      # non-app targets and skip them.
      unless user_target.name == 'Runner'
        user_target.build_phases
          .select { |p| p.respond_to?(:name) && p.name == phase_name }
          .each { |p| user_target.build_phases.delete(p) }
        next
      end

      existing = user_target.shell_script_build_phases.find { |p| p.name == phase_name }
      phase = existing || user_target.new_shell_script_build_phase(phase_name)
      # The embedded LiteRtLm binary is an INPUT so the phase re-runs whenever
      # Flutter's always-out-of-date `embed` phase re-copies the raw, unpatched
      # binary over the patched one. Without it Xcode caches the phase after the
      # first build and the second incremental build ships an unpatched
      # LiteRtLm that fails dlopen at runtime (#368).
      phase.input_paths = [
        '$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm',
      ]
      # A declared output lets Xcode order the phase in its dependency graph
      # instead of treating it as "runs every build with no outputs" — the other
      # half of the cycle warning (#300). The script touches this file.
      phase.output_paths = ['$(DERIVED_FILE_DIR)/flutter_gemma_litertlm_macos.stamp']
      phase.shell_script = <<~SHELL
        set -e
        STAGER="${HOME}/Library/Caches/flutter_gemma/native/macos_arm64/stage_macos_companions.sh"
        if [ ! -f "${STAGER}" ]; then
          echo "[flutter_gemma] ERROR: ${STAGER} not found." >&2
          echo "  flutter_edge_ai_litertlm installs it there from its build hook." >&2
          echo "  Upgrade the package, then: flutter clean && flutter pub get" >&2
          exit 1
        fi
        sh "${STAGER}" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Frameworks"
        mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
        touch "${SCRIPT_OUTPUT_FILE_0}"
      SHELL
    end
  end
end
```

Without it the build succeeds and the model fails to load at runtime.

## Windows and Linux

Nothing to add to the project. The native libraries — including the Windows GPU
shader compiler and NPU runtime — are bundled at build time.

- Windows: `x64` only — no Windows on Arm build. End users need no VC++
  redistributable installed. (In the legacy `flutter_gemma_litertlm` package
  this arrived in 1.7.1.) Measured on `native-v0.18.0-g`:
  17 of the bundle's 25 DLLs import no C++ runtime; the other eight, the Intel
  NPU stack, import only `msvcp140`, `vcruntime140` and `vcruntime140_1`,
  which every Flutter Windows app already resolves.
- Windows Intel NPU: a bundle whose NPU blobs carry no weights (Intel's Gemma 4
  12B for Panther Lake, EmbeddingGemma 2 270m `_Intel_PTL`) makes the dispatch
  copy them to `%TEMP%\litert_ov_bank_<hex>.bin` at every load (5.55 GB and
  74.5 MB); closing the model deletes it. From `flutter_edge_ai_litertlm` 1.17.0
  the next Intel NPU load deletes the banks whose owner process is gone and the
  unowned ones written before the PC last started (Fast Startup does not
  count); an unowned bank written since then (an older release, the LiteRT-LM
  CLI) and `LITERT_OV_WEIGHTS_PATH` are kept.
- Linux: `x64` and `arm64`. Building needs
  `clang cmake ninja-build libgtk-3-dev lld`. GPU needs the vendor Vulkan
  driver; Mesa's `llvmpipe` software fallback cannot run Gemma 4.
- Linux arm64 NPU (Qualcomm boards: QCS6490, QCS8275, QCS9075, …) uses the same
  `qualcomm_npu: true` as Android; the build hook reads the QNN runtime out of
  Qualcomm's QAIRT SDK zip (about 32 MB by range request). On the board the
  user must be in group `fastrpc` and `qcom-fastrpc1` must be installed, or
  the bundle compiled for the SoC (`gemma-4-E2B-it_qualcomm_qcs8275.litertlm`),
  the one to use, is refused with the reason. A generic bundle never runs on
  the NPU on any platform: `npu` falls back to GPU, then CPU, for it, because
  it has no NPU graph.

## Web

All script tags go in `web/index.html` `<head>`, before Flutter boots.

`.litertlm` engine (LLMs through `window.Engine`; EmbeddingGemma 2 embedders,
flutter_edge_ai_litertlm 1.13.1+, through `window.EmbeddingEngine` — a page
without that line fails the embedder's load with an `EmbeddingLoadException`
naming it). Both run on WebGPU; for EmbeddingGemma 2 there is no CPU fallback
on Web, so a browser without WebGPU fails the embedder's load with an
`EmbeddingLoadException` that says so:

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/+esm');
  window.Engine = m.Engine;
  window.EmbeddingEngine = m.EmbeddingEngine;
  return m.Engine;
})();
</script>
```

Model storage helpers. Copy `cache_api.js` and `opfs_helper.js` from the
`flutter_edge_ai` package's `web/` directory into the app's `web/`, then:

```html
<script src="cache_api.js"></script>
<script src="opfs_helper.js"></script>
```

Find the package directory with
`grep -A1 '"name": "flutter_edge_ai"' .dart_tool/package_config.json`.

Storage mode, set in `FlutterEdgeAi.initialize(webStorageMode: ...)`:

| `WebStorageMode` | Use for |
| --- | --- |
| `cacheApi` (default) | models under about 2 GB |
| `streaming` | larger models — streams through OPFS |
| `none` | no persistence; downloads every launch |

The `.litertlm` web engine loads the web build of a model —
`gemma-4-E2B-it-web.litertlm` (2.0 GB, so use `streaming`), not
`gemma-4-E2B-it.litertlm`. It is text-only: an image or audio message throws
`UnsupportedError`. LoRA is not supported on any `.litertlm` path, native
included: a session `loraPath` throws `UnsupportedError`, and an adapter
installed with `withLora…` is downloaded but not applied. LoRA needs a MediaPipe
`.task` model (flutter-edge-ai-mediapipe) or, natively, a `.gguf` model
through `flutter_edge_ai_llama`. Gemma 4 thinking works.

A `--dart-define` token is compiled into `main.dart.js`, where every visitor can
read it. Serve web users a model from a repo that needs no token.
