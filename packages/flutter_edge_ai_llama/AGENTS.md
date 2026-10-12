# llama.cpp adapter maintenance

This workspace package adapts core's registries to published `llamadart 0.11.1`.
Core resolves locally in the workspace. Hosted consumer validation currently
requires core `>=2.2.1 <2.3.0`: patch updates include its imported-file restore
fix, while the pending 2.3.0 public-engine API migration remains outside the
current draft. GGUF embeddings are deferred; see `doc/deferred_embeddings.md`.

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
- Keep core below 2.3.0 until engine imports and Web resolution use its public SPI.
  Move GGUF routing to a dedicated core file type before release.
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
