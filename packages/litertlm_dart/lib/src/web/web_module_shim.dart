// How the page hands this release `@litert-lm/core`: the whole module, once,
// as `window.litertLm`, set by the module script that also sets
// `window.litertLmReady` (module scripts are deferred, so Dart can run before
// the import settles). Dart reads each member it calls from that one object
// when it calls it (`Engine` at an LLM create, `EmbeddingEngine` at an
// embedder create, `Backend` at both), so every member comes from the same
// module instance, and a later release that calls more of the module needs
// no new page line.
//
// Pure Dart, so the words are tested on the VM; litert_lm_js.dart reads the
// global.
library;

import 'web_runtime_version.dart';

/// The line of the page's module script that hands this release the
/// `@litert-lm/core` module, word for word.
const liteRtLmWebModuleShimLine = 'window.litertLm = m;';

/// The page's whole module script, word for word: the READMEs, the example
/// pages and the codelab pages carry exactly this (a test holds them to it).
const liteRtLmWebModuleShim =
    '<script type="module">\n'
    'window.litertLmReady = (async () => {\n'
    "  const m = await import('$liteRtLmWebModuleUrl');\n"
    '  $liteRtLmWebModuleShimLine\n'
    '  return m;\n'
    '})();\n'
    '</script>';

/// Why the page's `@litert-lm/core` cannot be used: `window.litertLm` is not
/// set (or is not an object), or lacks a member this release calls, or its
/// `Backend` is not the enum this release reads. A [StateError], as every
/// other refusal of a page that does not load the runtime this release
/// calls; its message names what to change.
class LiteRtLmWebModuleError extends StateError {
  LiteRtLmWebModuleError(super.message);
}

/// The refusal of a page without `window.litertLm`. [legacyPage]: the page
/// still sets the separate globals of the shim of litertlm_dart 0.19.1+4 and
/// earlier (`window.Engine`, `window.EmbeddingEngine`). [what]: what
/// `window.litertLm` is when it is set but is not an object, null when it is
/// not set.
String liteRtLmWebModuleMissingMessage({
  required bool legacyPage,
  String? what,
}) {
  if (what != null) {
    return 'window.litertLm is $what, not the @litert-lm/core module: the '
        'page\'s module script must set it with $liteRtLmWebModuleShimLine '
        '(litertlm_dart\'s README, "On the web").';
  }
  if (legacyPage) {
    return 'window.litertLm is not set, but window.Engine or '
        'window.EmbeddingEngine is: this page '
        'uses the shim of litertlm_dart 0.19.1+4 and earlier. In its module '
        'script, replace window.Engine = m.Engine; window.EmbeddingEngine = '
        'm.EmbeddingEngine; return m.Engine; with $liteRtLmWebModuleShimLine '
        'return m; (litertlm_dart\'s README, "On the web").';
  }
  return 'window.litertLm is not set: the page does not hand this release '
      '@litert-lm/core. Add the module script from litertlm_dart\'s README '
      '("On the web"), which imports $liteRtLmWebModuleUrl and sets '
      '$liteRtLmWebModuleShimLine';
}

/// The refusal of a module without [member], which is [what] there (`a value
/// of type undefined`, ...).
String liteRtLmWebModuleMemberMessage(String member, String what) =>
    'window.litertLm has no $member ($what): the page\'s @litert-lm/core is '
    'not one this release calls. Import $liteRtLmWebModuleUrl in its module '
    'script.';
