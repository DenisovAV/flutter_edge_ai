# llama.cpp adapter maintenance

This workspace package adapts core's registries to published `llamadart 0.11.1`.
Core resolves locally in the workspace; standalone consumer/publish validation
requires the exact `flutter_edge_ai 2.2.0` contract (currently unreleased).

- Use Flutter 3.47.1, matching `.flutter-version` and the root `.fvmrc`.
- Run `python3 tool/verify.py contracts` and `python3 tool/verify.py package`
  from this package. The default package lane removes workspace resolution and
  validates hosted consumer dependencies; it fails until the exact core is published.
  For PR preparation, use `python3 tool/verify.py package --core-path ../flutter_edge_ai`:
  this checks the archive against a matching staged local core and explicitly does
  not qualify hosted consumer resolution. The hosted lane is required before release.
- Root `tool/test_all.sh` discovers this package and its demo automatically.
- `.github/workflows/llama.yml` owns the model/device and six-platform lanes;
  `.github/actions/setup-flutter-llama` pins the SDK's exact Git revision.
- Keep Flutter lanes sequential in one checkout; separate CI jobs are isolated.
- Keep exact dependency pins until public core APIs replace the restore/Web shims.
- Runtime source ownership stays in llamadart-native / llama-web-bridge.
- Never patch downloaded SDK, package, model or runtime sources to pass tests.
- Required model lanes fail if fixtures are missing. Qualification claims require
  the exact model, platform/device and backend evidence in `doc/platforms.md`.
- macOS/Windows CI model tests use the packaged desktop host to qualify the
  framework/DLL layout. A hosted macOS VM timeout is unresolved; local macOS VM
  inference passed. Raw Windows Flutter VM inference is unqualified with these pins.
- Hosted Apple/Android runtime lanes use an explicit single-thread CPU budget
  via `--cpu-threads 1`; keep all semantic/lifecycle assertions intact and record
  this profile separately from default-thread performance qualification.
- Consumer applications select llama.cpp through their own root hook settings;
  the workspace's selection does not propagate to external consumers.
- Publishing and final package ownership remain separate maintainer decisions.
