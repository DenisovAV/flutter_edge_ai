# llama.cpp adapter maintenance

This workspace package adapts core's registries to published `llamadart 0.11.1`.
Core resolves locally in the workspace; hosted consumer validation requires
the next published core patch containing #649. Shipped code uses only core's public engine libraries.
GGUF routes by its dedicated type from merged core #649. Hosted 2.3.1 lacks
that enum; this is development preparation until the patch is published. GGUF embeddings are deferred; see `doc/deferred_embeddings.md`.

- Use Flutter 3.47.1, matching `.flutter-version` and the root `.fvmrc`.
- Run `python3 tool/verify.py contracts` and `python3 tool/verify.py package`
  from this package. The package lane removes workspace resolution and validates
  published dependencies. The optional `--core-path ../flutter_edge_ai` lane
  prepares against the dependency's minimum core version and never qualifies
  hosted resolution.
- Root `tool/test_all.sh` discovers this package and its demo automatically.
- `.github/workflows/llama.yml` owns the model/device and six-platform lanes;
  `.github/actions/setup-flutter-llama` pins the SDK's exact Git revision.
- Keep Flutter lanes sequential in one checkout; separate CI jobs are isolated.
- Use `engine.dart` and the conditional Web-only `engine_web.dart`; never ship
  core `src/` imports. Test fixtures must annotate justified private imports.
  Keep dedicated GGUF routing; replace preparation validation with hosted
  validation and set its published dependency floor once #649 is released.
- Runtime source ownership stays in llamadart-native / llama-web-bridge.
- Never patch downloaded SDK, package, model or runtime sources to pass tests.
- Required model lanes fail if fixtures are missing. Qualification claims require
  the exact model, platform/device and backend evidence in `doc/platforms.md`.
- macOS/Windows CI model tests use the packaged desktop host to qualify the
  framework/DLL layout. A hosted macOS VM timeout is unresolved; local macOS VM
  inference passed. Raw Windows Flutter VM inference is unqualified with these pins.
- Hosted Apple/Android runtime lanes use an explicit single-thread CPU budget
  via `--cpu-threads 1`; keep all semantic/lifecycle assertions intact and record
  this profile separately from default-thread performance qualification. Apple
  CPU CI disables Metal enumeration with the pinned upstream
  `GGML_METAL_DEVICES=0` (`SIMCTL_CHILD_` for iOS) to avoid cold shader compilation
  during global backend registration; this is not GPU qualification.
- Consumer applications select llama.cpp through their own root hook settings;
  the workspace's selection does not propagate to external consumers.
- Publishing and final package ownership remain separate maintainer decisions.
