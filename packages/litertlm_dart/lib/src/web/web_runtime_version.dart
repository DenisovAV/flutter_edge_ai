// The `@litert-lm/core` release the web arm is written and measured against:
// the one place the version lives. An app's page imports exactly this version
// (`liteRtLmWebModuleUrl`); every message that names the runtime quotes it. In
// this repository, test/web/web_runtime_version_test.dart holds the example
// pages, the READMEs and the web goldens to it.

/// The `@litert-lm/core` version the web arm drives.
const liteRtLmWebRuntimeVersion = '0.19.0';

/// The ES module the page imports, pinned to [liteRtLmWebRuntimeVersion].
const liteRtLmWebModuleUrl =
    'https://cdn.jsdelivr.net/npm/@litert-lm/core@$liteRtLmWebRuntimeVersion/+esm';

/// `@litert-lm/core` with its version, as messages name it.
const liteRtLmWebRuntime = '@litert-lm/core $liteRtLmWebRuntimeVersion';

/// The message refusing an image or audio file path on the web.
const webMediaPathMessage =
    'On the web an image or audio part is its bytes (Content.imageBytes, '
    'Content.audioBytes): the page cannot read a file path.';
