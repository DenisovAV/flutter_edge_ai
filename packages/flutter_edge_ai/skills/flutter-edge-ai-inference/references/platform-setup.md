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

## iOS

Minimum iOS 15.0 — 16.0 if the app includes `flutter_edge_ai_mediapipe`.

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

In Xcode, under **Signing & Capabilities**, add **Extended Virtual Addressing**
and **Increased Memory Limit**. That writes these keys to
`ios/Runner/Runner.entitlements` and links the file to the target — a file
edited by hand but not linked does nothing. Without them large models are
killed for memory:

```xml
<key>com.apple.developer.kernel.extended-virtual-addressing</key>
<true/>
<key>com.apple.developer.kernel.increased-memory-limit</key>
<true/>
```

The iOS Simulator cannot run GPU inference; use CPU there, or a real device.

## macOS

Add to both `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

`network.client` lets the sandboxed app download the model.
`disable-library-validation` matters once Hardened Runtime is on, which
notarization requires: the build phase below signs LiteRT-LM and its companion
libraries ad hoc, and library validation refuses code that is not signed by
Apple or by the app's own team. Add both keys to both files — the debug and
release builds read different ones.

Do not copy the iOS `com.apple.developer.kernel.*` keys into these files; they
are iOS entitlements. Without a signing team the build fails with `"Runner" has
entitlements that require signing with a development certificate`, and a
team-signed build silently drops them. A `.litertlm` model loads on macOS
without them.

`.litertlm` on macOS also needs a build phase that copies the LiteRT-LM
companion libraries into the app: the package deliberately keeps them out of
Native Assets, so nothing else puts them in the bundle.

With CocoaPods, paste this into `macos/Podfile`, replacing any existing
`post_install` block, then run `pod install`.

**A Swift Package Manager app has no `macos/Podfile` to paste into.** SPM is the
default since Flutter 3.44, and an app whose plugins all ship a `Package.swift` —
core does, and `flutter_edge_ai_litertlm` is not a plugin at all — never gets one
generated. Either turn SPM off for the project
(`flutter config --no-enable-swift-package-manager`, then
`flutter build macos --config-only`, which writes the Podfile), or add the same
step by hand in Xcode: a Run Script phase on the Runner target named
`[flutter_gemma] Setup LiteRT-LM macOS`, carrying the `shell_script`, input path
and output path from the block below. The `flutter_gemma` phase, cache and stamp
names in this snippet are intentional compatibility identifiers used by the
current package; do not rename them.

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
  # flutter_gemma_litertlm and is delivered next to the dylibs it stages. That
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
          echo "  flutter_gemma_litertlm 1.6.2+ installs it there from its build hook." >&2
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

- Windows: end users need nothing installed. The current
  `flutter_edge_ai_litertlm` package includes the static-CRT fix; in the legacy
  `flutter_gemma_litertlm` package it arrived in 1.7.1.
  LiteRtLm.dll is linked against the static CRT and imports none;
  16 of its 24 DLLs import none. The other eight are the Intel NPU stack behind
  PreferredBackend.npu — our own LiteRtDispatch.dll plus Intel's openvino* and
  tbb* — importing only msvcp140/vcruntime140/vcruntime140_1, what a Flutter
  Windows app already resolves, and never vcruntime140_threads.dll (#456).
- Linux: building needs `clang cmake ninja-build libgtk-3-dev lld`. GPU needs the
  vendor Vulkan driver; Mesa's `llvmpipe` software fallback cannot run Gemma 4.

## Web

All script tags go in `web/index.html` `<head>`, before Flutter boots.

`.litertlm` engine:

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.17.1/+esm');
  window.Engine = m.Engine;
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
`gemma-4-E2B-it.litertlm`. It is text-only: no images, audio or LoRA, and no
Gemma 4 thinking.

A `--dart-define` token is compiled into `main.dart.js`, where every visitor can
read it. Serve web users a model from a repo that needs no token.
