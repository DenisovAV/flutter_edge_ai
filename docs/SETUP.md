# Development setup (macOS, Apple Silicon)

Written for this Mac on 2026-10-04: Apple M5 Pro, macOS 26.3, Homebrew installed, Android
SDK present at `~/Library/Android/sdk` (platform 37, no system images, no Java), no Xcode
(Command Line Tools only), no Flutter, Dart or FVM.

The repo pins Flutter in `.fvmrc`. Use that version; the `flutter_edge_ai_sqlite` package
needs 3.47 or newer and the rest need 3.44 or newer.

## 1. Flutter

Installed 2026-10-04: Flutter 3.47.6 (stable) at `~/flutter`, and a standalone Dart SDK via
Homebrew. `~/.zshrc` puts `~/flutter/bin` on the PATH (a backup of the previous file is at
`~/.zshrc.bak-2026-10-04`). Open a new terminal, then:

```bash
flutter --version
```

FVM is optional. `.fvmrc` pins 3.47.0 for anyone who uses it; the installed 3.47.6 is the
same minor version and is what CI will use.

## 2. Verify the pure-Dart packages first

These need only the Dart that ships inside Flutter. No device, no Xcode.

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind/packages/vehicle_finance" && dart pub get && dart test
```

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind/packages/advisor_core" && dart pub get && dart test
```

Both pass as of 2026-10-04 (31 and 27 tests).

## 3. Android

1. Install Android Studio (already present) and open **SDK Manager**. Install:
   - Android SDK Platform 35 or newer, plus **Android SDK Command-line Tools (latest)**.
   - **Android Emulator** and an **arm64-v8a** system image (Google APIs, API 35). On
     Apple Silicon only arm64 images run, and only arm64 can load the on-device LLM
     engine; x86_64 images will not run the model.
2. Java: Android Studio bundles a JDK. Point Flutter at it:

```bash
flutter config --jdk-dir "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

3. Accept licenses:

```bash
flutter doctor --android-licenses
```

4. Create an emulator (Device Manager, Pixel 8 Pro, API 35, arm64) with at least **6 GB
   RAM** so a 2.4 GB model fits with headroom.

Real device: enable developer options and USB debugging on the Samsung Fold 4, plug in,
`flutter devices`.

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
flutter doctor -v
```

Everything except "Chrome" and "VS Code" should be green. Paste the output into the chat if
not.

## 6. The app

`apps/motormind` was generated on 2026-10-04 with
`flutter create --org com.sirisdevelopment --project-name motormind --platforms android,ios --empty`
and is a member of the root pub workspace. Resolve and test from the repo root:

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo" && flutter pub get && flutter analyze apps/motormind
```

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind" && flutter test
```

Run on a device or arm64 emulator:

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind" && flutter run
```

## 7. Hugging Face token (for Gemma models)

Gemma downloads need a Hugging Face account that has accepted the Gemma license, and a
read token. The app will ask for it on first download and store it in secure storage. Never
commit it. Qwen3 needs no token.
