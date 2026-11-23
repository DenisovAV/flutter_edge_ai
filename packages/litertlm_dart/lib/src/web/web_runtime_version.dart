// The `@litert-lm/core` release the web arm is written and measured against:
// the one place the version lives. The page's module script imports exactly
// this version (`liteRtLmWebModuleUrl`), and every message that names the
// runtime quotes it; test/web/web_runtime_version_test.dart holds the example's
// index.html and the READMEs to it.

/// The `@litert-lm/core` version the web arm drives.
const liteRtLmWebRuntimeVersion = '0.19.0';

/// The ES module the page imports, pinned to [liteRtLmWebRuntimeVersion].
const liteRtLmWebModuleUrl =
    'https://cdn.jsdelivr.net/npm/@litert-lm/core@$liteRtLmWebRuntimeVersion/+esm';

/// `@litert-lm/core` with its version, as messages name it.
const liteRtLmWebRuntime = '@litert-lm/core $liteRtLmWebRuntimeVersion';
