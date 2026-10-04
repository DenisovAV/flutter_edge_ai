# Development setup (macOS, Apple Silicon)

Written for this Mac on 2026-10-04: Apple M5 Pro, macOS 26.3, Homebrew installed, Android
SDK present at `~/Library/Android/sdk` (platform 37, no system images, no Java), no Xcode
(Command Line Tools only), no Flutter, Dart or FVM.

The repo pins Flutter in `.fvmrc`. Use that version; the `flutter_edge_ai_sqlite` package
needs 3.47 or newer and the rest need 3.44 or newer.

## 1. Flutter via FVM

FVM (Flutter Version Management) keeps per-project Flutter versions so this repo's pin
does not fight other projects.

```bash
brew tap leoafarias/fvm && brew install fvm
```

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo" && fvm install && fvm use
```

`fvm install` reads `.fvmrc` and downloads that Flutter (about 1 GB). `fvm use` links it
at `.fvm/flutter_sdk`, which is git-ignored. From then on run every Flutter and Dart
command through FVM:

```bash
fvm flutter --version
```

Optional: add `alias flutter="fvm flutter"` and `alias dart="fvm dart"` to `~/.zshrc`, or
put `.fvm/flutter_sdk/bin` on your PATH while in this repo. The docs below spell out `fvm`.

## 2. Verify the pure-Dart packages first

These need only the Dart that ships inside Flutter. No device, no Xcode.

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind/packages/vehicle_finance" && fvm dart pub get && fvm dart test
```

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind/packages/advisor_core" && fvm dart pub get && fvm dart test
```

If either fails, paste the output into the chat; the code was written before a Dart SDK
was available on this machine and has not been compiled yet.

## 3. Android

1. Install Android Studio (already present) and open **SDK Manager**. Install:
   - Android SDK Platform 35 or newer, plus **Android SDK Command-line Tools (latest)**.
   - **Android Emulator** and an **arm64-v8a** system image (Google APIs, API 35). On
     Apple Silicon only arm64 images run, and only arm64 can load the on-device LLM
     engine; x86_64 images will not run the model.
2. Java: Android Studio bundles a JDK. Point Flutter at it:

```bash
fvm flutter config --jdk-dir "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

3. Accept licenses:

```bash
fvm flutter doctor --android-licenses
```

4. Create an emulator (Device Manager, Pixel 8 Pro, API 35, arm64) with at least **6 GB
   RAM** so a 2.4 GB model fits with headroom.

Real device: enable developer options and USB debugging on the Samsung Fold 4, plug in,
`fvm flutter devices`.

## 4. iOS

1. Install **Xcode** from the App Store (around 15 GB), open it once, accept the license,
   and install the iOS platform when prompted. Then:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch
```

2. CocoaPods, used by Flutter plugins:

```bash
brew install cocoapods
```

3. The iOS Simulator runs the model on CPU only (Metal has a 256 MB single-allocation
   cap in the simulator), so it is slow but works for UI. A physical iPhone needs an Apple
   Developer account for signing; the free personal team works for development installs
   with a seven-day expiry.

## 5. Check everything

```bash
fvm flutter doctor -v
```

Everything except "Chrome" and "VS Code" should be green. Paste the output into the chat if
not.

## 6. Create the app (first time only)

The app scaffold has not been generated yet because `flutter create` needs the SDK. When
the toolchain is ready, the first engineering story (VA-0.3.1 in `BACKLOG.md`) runs:

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps" && fvm flutter create --org com.sirisdevelopment --project-name motormind --platforms android,ios motormind
```

That command does not overwrite `apps/motormind/packages/`, which already exists.
Afterwards the root `pubspec.yaml` gets `apps/motormind` added to its `workspace:` list and
the app's `pubspec.yaml` gets `resolution: workspace`.

## 7. Hugging Face token (for Gemma models)

Gemma downloads need a Hugging Face account that has accepted the Gemma license, and a
read token. The app will ask for it on first download and store it in secure storage. Never
commit it. Qwen3 needs no token.
