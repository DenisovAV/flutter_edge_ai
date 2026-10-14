# Flutter Edge AI Example App

## Setup

### 1. Configure HuggingFace Token (Optional)

⚠️ **Note:** A Hugging Face token is required for the gated repositories below:

**Token Required (gated):**
- Gemma3n E2B/E4B (`google/gemma-3n-*`)
- Gemma 3 1B and Gemma 3 270M (`litert-community/Gemma3-*`, `litert-community/gemma-3-*`)
- EmbeddingGemma (all sizes)

**Token NOT Required (public repos):**
- Gemma 4 E2B/E4B, FunctionGemma 270M
- FastVLM, Qwen3, Qwen 2.5, DeepSeek R1, Phi-4 Mini, SmolLM
- Gecko embedding models
- Local asset / bundled models

**Most models in the app work without a token!** Configure it only if you need Gemma3n, Gemma 3, or EmbeddingGemma:

**Step 1:** Copy the config template:
```bash
cp config.json.example config.json
```

**Step 2:** Edit `config.json` and add your HuggingFace token:
```json
{
  "HUGGINGFACE_TOKEN": "hf_your_token_here"
}
```

**Step 3:** Get your token from: https://huggingface.co/settings/tokens

**Step 4:** Grant access to gated repos:
- Visit model page (e.g., https://huggingface.co/google/gemma-3n-E2B-it-litert-preview)
- Click "Request Access" button

### 2. Run the App

**With configuration:**
```bash
flutter run --dart-define-from-file=config.json
```

**With token directly (without config file):**
```bash
flutter run --dart-define=HUGGINGFACE_TOKEN=hf_your_token_here
```

**Without configuration** (works for public and local models):
```bash
flutter run
```

**Tiny Island (3D):** tell a character on a small 3D island what to do in
your own words; core's Decider (`EmbeddingModel.createDecider`, experimental)
over the active embedding model picks one of 184 actions, or abstains. Choose
an EmbeddingGemma 2 bundle under Embedding Models first (Text 270M is the
lightest; a per-SoC NPU bundle runs on the NPU).

- **Platforms.** The scene renders with
  [flutter_scene](https://pub.dev/packages/flutter_scene) through Flutter GPU,
  which this app's Android, iOS and macOS manifests turn on
  (`EnableFlutterGPU` / `FLTEnableFlutterGPU`). The web renders through
  flutter_scene's WebGL2 backend, and EmbeddingGemma 2 there needs WebGPU: a
  browser without it gets that message, not a model list. On Windows and
  Linux the home card is disabled: the runners do not enable Flutter GPU.
- **First visit.** The Decider embeds the 920 action texts and 144 held-out
  calibration requests once per model (67–82 s measured on an M4 Pro CPU, a
  debug build, while the scene loads), then stores the fitted decider
  (`Decider.toArtifact()`, 0.8 MB) in the app's
  cache directory — not application support, which iCloud and Android Auto
  Backup copy. Later visits load it (`loadDecider`, 0.6–1.2 s with the model
  load). On the web it is kept in memory only, so every page load fits it
  again.
- **Build hook and the pub cache.** `hook/build.dart` converts
  `assets/island/models/*.glb` (Kenney, CC0) at build time. flutter_scene's
  own build hook also writes generated shader bundles into its package
  directory in the shared pub cache (`flutter_scene-<version>/
  flutter_scene_generated/`). Two checkouts that build the example with
  different Flutter versions at once can overwrite each other's bundle there,
  and a read-only `PUB_CACHE` fails the build: build one checkout at a time
  when they use different Flutter versions.

### 3. Local Models Setup (Optional)

If you want to test local models like `Gemma 3 1B IT (Local)`:

1. Download the model file from HuggingFace
2. Place it in the appropriate location:
   - `assets/models/gemma3-1b-it-int4.task` in the example app — one Flutter
     asset for Android, iOS and Web (on Web, production builds only)
3. Ensure the file is listed in `pubspec.yaml` under `flutter: assets:`

```yaml
flutter:
  assets:
    - assets/models/gemma3-1b-it-int4.task
    - assets/models/gemma-3n-E2B-it-int4.task
```

### 4. Build for Production

```bash
flutter build apk --dart-define-from-file=config.json
flutter build ios --dart-define-from-file=config.json
flutter build web --dart-define-from-file=config.json
```

## Security Notes

- ⚠️ **Never commit `config.json`** - it contains your private token
- ✅ `config.json.example` is the template (safe to commit)
- ✅ `config.json` is in `.gitignore` (automatically excluded)

## Testing

The app includes integration tests for:
- Model downloads (public and private)
- Asset model loading
- Bundled model loading
- Inference and embedding generation
