import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../executors/js_skill_executor.dart';
import '../skill.dart';
import '../skill_md_parser.dart';

/// The name of every starter skill bundled with this package, in the order they
/// are presented to the user. Ported verbatim from google-ai-edge/gallery
/// (Apache-2.0) — their `SKILL.md` + `scripts/index.html` parse and run
/// unmodified (the JS keeps the `window.ai_edge_gallery_get_result` contract).
///
/// Covers all four skill mechanisms:
/// * JS (`run_js`): `calculate-hash`, `qr-code`, `query-wikipedia`,
///   `interactive-map` (the last one returns a webview);
/// * native-intent (`run_intent`): `send-email`, `create-calendar-event`;
/// * text-only persona: `kitchen-adventure`.
const List<String> bundledSkillNames = [
  'calculate-hash',
  'qr-code',
  'query-wikipedia',
  'interactive-map',
  'send-email',
  'create-calendar-event',
  'get-current-time',
  'kitchen-adventure',
];

/// This package's name — the prefix Flutter prepends to assets declared by a
/// dependency. A bundled asset at `assets/skills/<name>/...` in this package is
/// addressed from the host app as `packages/flutter_gemma_agent/assets/...`.
const String _packageName = 'flutter_gemma_agent';

/// Loads the SKILL.md skills bundled with this package from its Flutter assets.
///
/// The skills live under `assets/skills/<name>/SKILL.md` (declared in this
/// package's `pubspec.yaml`). Because they ship inside a dependency, the host
/// app sees them under the `packages/flutter_gemma_agent/` prefix — this source
/// builds those keys for you, so you never hand-write them.
///
/// Usage:
/// ```dart
/// final source = AssetSkillSource();
/// final skills = await source.load();
/// final registry = SkillRegistry()..addAll(skills, selected: true);
///
/// // Wire the JS executor so it can find each skill's bundled HTML:
/// final js = JsSkillExecutor(sourceFor: source.jsSkillSourceFor);
/// ```
///
/// The [bundle] is injectable so the loader is unit-testable against a fake
/// [AssetBundle]; it defaults to [rootBundle].
class AssetSkillSource {
  AssetSkillSource({AssetBundle? bundle, List<String>? names})
    : _bundle = bundle ?? rootBundle,
      names = List.unmodifiable(names ?? bundledSkillNames);

  final AssetBundle _bundle;

  /// The skill names this source loads (defaults to [bundledSkillNames]).
  final List<String> names;

  /// The Flutter asset key for a bundled skill's `SKILL.md`, with the
  /// `packages/<this-package>/` prefix the host app addresses it by.
  static String skillMdKey(String name) =>
      'packages/$_packageName/assets/skills/$name/SKILL.md';

  /// The Flutter asset key for a bundled JS skill's runnable HTML
  /// (`assets/skills/<name>/scripts/<scriptName>`), prefixed for the host app.
  static String scriptKey(String name, [String scriptName = 'index.html']) =>
      'packages/$_packageName/assets/skills/$name/scripts/$scriptName';

  /// Load + parse every bundled [names] entry into a [Skill]. Each skill's
  /// asset name (its directory) is preserved as [Skill.name] via the SKILL.md
  /// frontmatter, so it matches what [jsSkillSourceFor] expects.
  ///
  /// Skips (does not throw on) a skill whose asset is missing or whose SKILL.md
  /// fails to parse — a malformed bundled skill must not take down the whole
  /// catalog. Returns the successfully-parsed skills in [names] order.
  Future<List<Skill>> load() async {
    final skills = <Skill>[];
    for (final name in names) {
      try {
        final content = await _bundle.loadString(skillMdKey(name));
        skills.add(parseSkillMd(content));
      } catch (_) {
        // Missing/invalid bundled skill — skip it rather than fail the catalog.
        continue;
      }
    }
    return skills;
  }

  /// Resolves a [skill] to the [JsSkillSource] for its bundled HTML, ready to
  /// pass as [JsSkillExecutor.sourceFor]. Uses the skill's [Skill.scriptName]
  /// (defaults to `index.html`) under this package's `scripts/` asset dir.
  ///
  /// Only meaningful for [SkillType.js] skills; the JS executor only calls this
  /// for skills it can execute, so the returned source for a non-JS skill is
  /// never loaded.
  JsSkillSource jsSkillSourceFor(Skill skill) =>
      JsSkillSource.asset(scriptKey(skill.name, skill.scriptName));
}
