# llama.cpp adapter maintenance

This package adapts core 2.3.2+ through public engine libraries to published
llamadart 0.11.1. GGUF routes only by its declared type. GGUF embeddings are deferred.

- Minimum Flutter/Dart follows core (3.44/3.12). Connector CI pins Flutter 3.47.1
  for reproducible checks; do not raise the whole workspace floor for this adapter.
- Run `python3 tool/verify.py contracts` and `python3 tool/verify.py package`.
  The latter validates hosted consumers without workspace resolution or overrides.
- Shipped code uses `engine.dart` and conditional `engine_web.dart`, never core src.
- Public exports are the provider, projector resolver and two tool types.
  Implementation classes and diagnostics stay internal; the named loader seam is test-only.
- Model/device lanes require machine-reported execution of the selected smoke.
  Optional features use `verify.py capabilities` with explicit compatible fixtures.
- Apple/Android CI CPU profiles use one thread. Apple CPU lanes disable Metal
  enumeration with `GGML_METAL_DEVICES=0`; this is not GPU qualification.
- Native source ownership stays in llamadart-native; Web assets in llama-web-bridge-assets.
  Do not patch downloaded SDKs, runtimes or models to pass tests.
- Consumers select `[llama_cpp]` in their root hooks; this is mandatory beside
  Flutter Edge AI LiteRT-LM to avoid runtime collisions. Settings do not propagate.
- Keep [platforms.md](doc/platforms.md) current; qualification history belongs in the PR.
- Publication, ownership, copyright and bundle IDs require maintainer decisions.
