# Flutter Gemma Example App

## Setup

### 1. Configure HuggingFace Token (Optional)

⚠️ **Note:** HuggingFace token is required for **Google-gated repos only**:

**Token Required (gated):**
- Gemma3n E2B/E4B (`google/gemma-3n-*`)
- EmbeddingGemma (all sizes)

**Token NOT Required (public repos):**
- Gemma 4 E2B/E4B, Gemma 3 1B, Gemma 3 270M, FunctionGemma 270M
- FastVLM, Qwen3, Qwen 2.5, DeepSeek R1, Phi-4 Mini, SmolLM
- Gecko embedding models
- Local asset / bundled models

**Most models in the app work without a token!** Configure it only if you need Gemma3n or EmbeddingGemma:

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

### 3. Local Models Setup (Optional)

If you want to test local models like `Gemma 3 1B IT (Local)`:

1. Download the model file from HuggingFace
2. Place it in the appropriate location:
   - **Android:** `android/app/src/main/assets/models/gemma3-1b-it-int4.task`
   - **iOS:** Add to Xcode project under Resources
   - **Web:** `web/assets/models/gemma3-1b-it-int4.task` (production builds only)
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
