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

/// Thrown by [AssetSkillSource.load] when a requested skill does not yield a
/// [Skill]. A [StateError], like the package's other configuration and
/// packaging failures, so `on StateError` keeps catching it; [failures] says
/// which skills failed and why.
class BundledSkillLoadError extends StateError {
  BundledSkillLoadError(this.failures)
    : super(
        'Bundled skills could not be loaded:\n'
        '${failures.entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}\n'
        'A name outside bundledSkillNames, a copy of $_packageName published '
        'without its SKILL.md files (every version up to 0.2.6), or a build or '
        'web deployment that does not serve the package assets '
        '(assets/packages/$_packageName/assets/skills/) causes this.',
      );

  /// Skill name to the reason it did not load, in requested order.
  final Map<String, String> failures;
}

/// This package's name — the prefix Flutter prepends to assets declared by a
/// dependency. A bundled asset at `assets/skills/<name>/...` in this package is
/// addressed from the host app as `packages/flutter_edge_ai_agent/assets/...`.
const String _packageName = 'flutter_edge_ai_agent';

/// Loads the SKILL.md skills bundled with this package from its Flutter assets.
///
/// The skills live under `assets/skills/<name>/SKILL.md` (declared in this
/// package's `pubspec.yaml`). Because they ship inside a dependency, the host
/// app sees them under the `packages/flutter_edge_ai_agent/` prefix — this source
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

  /// Loads and parses the SKILL.md of every [names] entry, returning one
  /// [Skill] per name in [names] order. Each skill's [Skill.name] must equal
  /// its directory name, which is what [jsSkillSourceFor] builds keys from.
  ///
  /// Throws a [BundledSkillLoadError] naming every skill that did not yield a
  /// [Skill], with the reason: the asset could not be loaded (the original
  /// error is kept), the server returned an HTML page in its place, the file
  /// does not parse, or its frontmatter name is not its directory. Every
  /// bundled SKILL.md is tested to parse, so any of these means the files
  /// that reached the app are not the ones this package ships — and a quiet
  /// skip is what let every version up to 0.2.6 return an empty catalog.
  Future<List<Skill>> load() async {
    final skills = <Skill>[];
    final failures = <String, String>{};
    for (final name in names) {
      final key = skillMdKey(name);
      final String content;
      try {
        content = await _bundle.loadString(key);
      } catch (e) {
        // A cached failed future would repeat this error for the rest of the
        // session, even once its cause (binding, network) is gone.
        _bundle.evict(key);
        failures[name] = 'could not be loaded: $e';
        continue;
      }
      if (_isHtmlPage(content)) {
        _bundle.evict(key);
        failures[name] =
            'the server answered with an HTML page instead (a web host that '
            'rewrites unknown paths to index.html)';
        continue;
      }
      final Skill skill;
      try {
        skill = parseSkillMd(content);
      } catch (e) {
        failures[name] = 'is not a valid SKILL.md: $e';
        continue;
      }
      if (skill.name != name) {
        failures[name] =
            'its frontmatter name "${skill.name}" is not its directory name';
        continue;
      }
      skills.add(skill);
    }
    if (failures.isNotEmpty) {
      // An error rather than a logged skip: an empty catalog makes the agent
      // answer skill requests itself, with no sign anything is wrong.
      throw BundledSkillLoadError(failures);
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

  /// An HTML document where a SKILL.md was expected: the app's own page,
  /// served by a web host for an asset path it does not have.
  static bool _isHtmlPage(String content) {
    final head = content.trimLeft().toLowerCase();
    return head.startsWith('<!doctype html') || head.startsWith('<html');
  }
}
