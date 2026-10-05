# On-device model options

What each candidate buys and costs, written for the model picker in the app and for the
"why this model" question in an interview. Facts about engines and formats come from the
upstream package docs in `packages/`; measured numbers will replace estimates once the
diagnostics screen exists (VA-1.4).

## What the app needs from a model

1. **Reliable tool calling.** The whole design depends on the model emitting a structured
   call (`estimate_payment`, `update_profile`, `present`) with the right arguments. A model
   that narrates instead of calling breaks the "numbers from tools" rule.
2. **Enough context.** A system prompt with tool descriptions and the component registry,
   the profile summary, a few turns, and a tool result is 2,000 to 4,000 tokens. The
   context window (`maxTokens` in this SDK is the *context*, not the reply length) should be
   4,096 or more.
3. **Fits in memory beside a webview.** A webview can take 300 to 600 MB. Rule of thumb:
   model file size times 1.3, plus 1 GB for the app and webview, must fit in the device's
   free RAM.
4. **Acceptable latency.** Time to first token under about 2 seconds and 8 or more tokens
   per second keep a chat usable. Extraction turns are short; narration turns are longer.

## Candidates

| Model | File | Size | Tool calls | Thinking | Vision | Notes |
|---|---|---|---|---|---|---|
| **Gemma 4 E2B** | `.litertlm` | 2.6 GB | native | yes | yes | Default. Best extraction and narration of the small set; needs ~4 GB free RAM. Public `litert-community` repo, no token. |
| Gemma 4 E4B | `.litertlm` | 4.3 GB | native | yes | yes | Better, but 6 GB+ free RAM. Fold 4 (12 GB) and iPhone 15 Pro (8 GB) can run it; most phones cannot. Offer as "high quality" only when the device qualifies. |
| **Qwen3 0.6B** | `.litertlm` | 586 MB | parsed | yes | no | "Light" option and the no-token path. Expect weaker extraction on messy sentences; the golden dataset will say by how much. |
| FunctionGemma 270M | `.litertlm` | 284 MB | native | no | no | Extraction specialist. Ends its turn at the call and does not narrate well, so it only works in a two-model configuration (extract with this, narrate with another). Experiment, not default. |
| Qwen 2.5 1.5B | `.task` | 1.6 GB | parsed | no | no | Older MediaPipe path; no desktop. Not planned. |
| Phi-4 Mini | `.litertlm` | 3.9 GB | parsed | no | no | Strong reasoning; too big for the mobile story. Desktop testing only, if at all. |
| OS built-in: Apple Foundation Models | none | 0 | varies | no | no | iOS 26+. No download, no gating. Tool-call reliability unverified in this SDK. Worth testing on the iPhone 15 Pro. |
| OS built-in: Gemini Nano | none | 0 | varies | no | no | Needs AICore, which ships on recent Pixel and Galaxy flagships. Confirmed absent on the Galaxy Z Fold 4 (2026-10-04), so documented only. |

Models not in the table (SmolLM, LFM2.5, Gemma 3 1B/270M, vision models) lack tool calling
and are not candidates.

## Why not one big model

Quality rises with size, but so does download time, storage, memory pressure and thermal
throttling. A 2.4 GB model on a phone is already a 5 to 15 minute download on home Wi-Fi.
The product answer is a short menu: a default that works on a mid-range phone, a light
option for older devices, and a high-quality option gated by a device check.

## Engines and backends

All candidates run through `flutter_edge_ai_litertlm` (LiteRT-LM over FFI) on Android and
iOS. Backend choice is per model at load time:

- **GPU** on both platforms is the normal choice for 1 GB+ models.
- **CPU** is the fallback and the only option in the iOS Simulator.
- **NPU** exists on Qualcomm Snapdragon Android devices for `.litertlm`; the Fold 4 has a
  Snapdragon 8+ Gen 1, so it is worth a measurement.

Only `arm64-v8a` Android and arm64 iOS are supported. x86_64 Android emulators cannot load
the engine; use arm64 system images on Apple Silicon.

## Delivery: OTA, not in the binary

App stores cap bundle sizes well under 2 GB, and a model update should not require an app
update. So models are downloaded after install:

1. The app ships a **model manifest**: id, display name, size, SHA-256, source URL, minimum
   free RAM, capability flags.
2. Download with progress, free-space check, retry, and checksum verification.
3. Source URLs point at the public `litert-community` repos on Hugging Face (no token for
   either catalog model; the raw `google/gemma-4-E2B` checkpoint is not usable) or at a
   self-hosted mirror (your web server; needs HTTPS and range requests for resume). The manifest can be fetched
   remotely so new models appear without an app release.

This is the "OTA binary delivery" story from the resume, made concrete.

## Switching at runtime

Model switching is: close the current session and model, load the selected one, rebuild
the chat with the same system prompt and profile summary. The conversation transcript is
kept; the new model simply sees it as history. Because every number comes from tools, a
weaker model changes wording, not figures.

## What to measure (VA-1.4)

Per model, per device, from the in-app diagnostics screen: cold start (model load),
time to first token, tokens per second during narration, peak anonymous memory, and the
extraction score on the golden dataset. Those five numbers are the model-picker's "device
fit" input and the README's table.
