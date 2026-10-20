# llama.cpp adapter maintenance

This draft adapts core 2.5.0+ through public engine libraries and published
llamadart 0.15.1. Source qualification uses the merged core source; standalone hosted
qualification still requires publication of core 2.5.0. Inference routes by declared type. LlamaEmbeddingBackend
registers self-contained GGUF through core's embedding SPI; see doc/embeddings.md.

- Minimum Flutter/Dart follows core (3.44/3.12). Connector CI pins Flutter 3.47.1
  for reproducible checks; verify.py also reads the workspace SDK from `.fvmrc`. Do not raise the whole workspace floor for this adapter.
- Run `python3 tool/verify.py contracts` and `python3 tool/verify.py package`.
  The latter validates hosted consumers without workspace resolution or overrides.
- Shipped code uses `engine.dart` and conditional `engine_web.dart`, never core src.
- Public exports are the inference provider, embedding backend and projector resolver. Tool messages use core types.
  Implementation classes and diagnostics stay internal; the loader factory is internal and test-only.
- Model/device lanes require machine-reported execution of the selected smoke.
  Optional features use `verify.py capabilities` with explicit compatible fixtures.
- Apple/Android CI CPU profiles use one thread. Apple CPU lanes disable Metal
  enumeration with `GGML_METAL_DEVICES=0`; this is not GPU qualification.
- Native source ownership stays in llamadart-native; Web assets in llama-web-bridge-assets.
  Do not patch downloaded SDKs, runtimes or models to pass tests.
- Consumers retain `[llama_cpp]` in root hooks as defence in depth. SDK 0.15.0
  chooses it automatically for this graph and rejects explicit LiteRT-LM collisions.
  Settings do not propagate. Apple workspace apps declare the companion directly
  in the app and hooks in the root; inconsistent companion choices remain unqualified.
- Keep [platforms.md](doc/platforms.md) current; qualification history belongs in the PR.
- Publication, ownership, copyright and bundle IDs require maintainer decisions.

- The SDK constraint targets one published patch (`>=0.15.1 <0.15.2`); the Apple
  companion is exact (`0.15.0`). Every SDK upgrade requires a coordinated
  connector release, matching companion, Web bridge and full qualification.
  Pub enforces the companion/core minor pairing, backed by Apple build guards; SDK 0.15.0 also constrains workspace
  hooks/code_assets below 3.0. Never silently widen these constraints.
