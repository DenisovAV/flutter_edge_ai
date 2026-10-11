# llama.cpp adapter maintenance

This workspace package adapts core's registries to published `llamadart 0.11.1`.
Core resolves locally in the workspace; standalone consumer/publish validation
uses the exact published `flutter_edge_ai 2.1.3` contract.

- Use Flutter 3.47.1, matching `.flutter-version` and the root `.fvmrc`.
- Run `python3 tool/verify.py contracts` and `python3 tool/verify.py package`
  from this package. The package lane removes workspace resolution in a staged
  standalone copy and validates the actual consumer dependency graph.
- Root `tool/test_all.sh` discovers this package and its demo automatically.
- `.github/workflows/llama.yml` owns the model/device and six-platform lanes;
  `.github/actions/setup-flutter-llama` pins the SDK's exact Git revision.
- Keep Flutter lanes sequential in one checkout; separate CI jobs are isolated.
- Keep exact dependency pins until public core APIs replace the restore/Web shims.
- Runtime source ownership stays in llamadart-native / llama-web-bridge.
- Never patch downloaded SDK, package, model or runtime sources to pass tests.
- Required model lanes fail if fixtures are missing. Qualification claims require
  the exact model, platform/device and backend evidence in `doc/platforms.md`.
- Windows model tests use the packaged desktop host; raw Flutter VM inference
  is unqualified with these pins.
- Consumer applications select llama.cpp through their own root hook settings;
  the workspace's selection does not propagate to external consumers.
- Publishing and final package ownership remain separate maintainer decisions.
