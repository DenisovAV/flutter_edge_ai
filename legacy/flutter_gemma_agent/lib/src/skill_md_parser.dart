import 'package:yaml/yaml.dart';

import 'skill.dart';

/// Thrown by [parseSkillMd] when the SKILL.md is structurally invalid
/// (no frontmatter, or missing `name`/`description`).
class SkillMdParseException implements Exception {
  SkillMdParseException(this.errors);

  /// One or more human-readable problems found while parsing.
  final List<String> errors;

  @override
  String toString() => 'SkillMdParseException: ${errors.join('; ')}';
}

/// Parses a SKILL.md document into a [Skill].
///
/// Format (Gallery-compatible — their catalog parses unmodified):
/// ```
/// ---
/// name: kebab-case-id
/// description: One-line summary the model uses to pick the skill.
/// metadata:
///   homepage: https://optional
///   require-secret: true
///   require-secret-description: how to obtain the key
/// ---
/// # Title
/// ## Instructions
/// Call the `run_js` tool …
/// ```
///
/// - `name` and `description` are required; everything in `metadata:` is
///   optional and tolerated-when-missing.
/// - The body (everything after the second `---`) becomes [Skill.instructions].
/// - [SkillType] is inferred from the body's tool mention: `run_js` → js,
///   `run_intent` → intent, `run_mcp` → mcp, otherwise textOnly.
///
/// Throws [SkillMdParseException] if there is no frontmatter or `name` /
/// `description` is missing.
Skill parseSkillMd(String content) {
  final errors = <String>[];

  // Gallery splits on '---': part[0] is the (usually empty) preamble, part[1]
  // is the frontmatter, and parts[2..] are the body (rejoined with '---' so a
  // '---' horizontal-rule inside the markdown body survives).
  final parts = content.split('---');
  if (parts.length < 3) {
    throw SkillMdParseException([
      "Invalid format: expected a '---' fenced YAML frontmatter block.",
    ]);
  }

  final frontmatter = parts[1].trim();
  final body = parts.skip(2).join('---').trim();

  final fields = _parseFrontmatter(frontmatter, errors);

  final name = (fields['name'] as String?)?.trim();
  final description = (fields['description'] as String?)?.trim();
  if (name == null || name.isEmpty) {
    errors.add("Missing or empty 'name' in the frontmatter.");
  }
  if (description == null || description.isEmpty) {
    errors.add("Missing or empty 'description' in the frontmatter.");
  }
  if (errors.isNotEmpty) {
    throw SkillMdParseException(errors);
  }

  final metadata = _parseMetadata(fields['metadata']);
  final type = inferSkillType(body);
  final scriptName = _inferScriptName(body);

  return Skill(
    name: name!,
    description: description!,
    instructions: body,
    type: type,
    metadata: metadata,
    scriptName: scriptName,
  );
}

/// Infers the [SkillType] from a SKILL.md instructions body by looking for the
/// tool it tells the model to call. Order matters only in that a body could in
/// theory mention several; the first match in (js, intent, mcp) wins, falling
/// back to [SkillType.textOnly] when no tool is mentioned.
SkillType inferSkillType(String body) {
  final lower = body.toLowerCase();
  if (lower.contains('run_js')) return SkillType.js;
  if (lower.contains('run_intent')) return SkillType.intent;
  if (lower.contains('run_mcp')) return SkillType.mcp;
  return SkillType.textOnly;
}

/// Parses the YAML frontmatter into a flat map. Uses `package:yaml` for
/// correctness, but falls back to a tolerant line parser if the block is not
/// valid YAML (some hand-authored SKILL.md files have loose indentation).
Map<String, dynamic> _parseFrontmatter(
  String frontmatter,
  List<String> errors,
) {
  try {
    final doc = loadYaml(frontmatter);
    if (doc is Map) {
      return doc.map((k, v) => MapEntry(k.toString(), v));
    }
    // Non-map YAML (e.g. a scalar) — fall through to the line parser.
  } catch (_) {
    // Not valid YAML — fall through to the tolerant line parser below.
  }
  return _parseFrontmatterLines(frontmatter);
}

/// Tolerant line-based frontmatter parser (mirrors Gallery's Kotlin parser):
/// top-level `name:` / `description:`, then a nested `metadata:` block of
/// `homepage` / `require-secret` / `require-secret-description`.
Map<String, dynamic> _parseFrontmatterLines(String frontmatter) {
  final out = <String, dynamic>{};
  final metadata = <String, dynamic>{};
  var inMetadata = false;

  for (final raw in frontmatter.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line == 'metadata:') {
      inMetadata = true;
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    if (!inMetadata) {
      out[key] = value;
    } else {
      metadata[key] = value;
    }
  }
  if (metadata.isNotEmpty) out['metadata'] = metadata;
  return out;
}

/// Builds [SkillMetadata] from the (possibly-null) parsed `metadata:` node.
/// Accepts both YAML kebab-case keys (`require-secret`) and the snake/camel
/// variants, and tolerates the whole block being absent.
SkillMetadata _parseMetadata(dynamic node) {
  if (node is! Map) return const SkillMetadata();
  final map = node.map((k, v) => MapEntry(k.toString(), v));

  String? str(List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v != null) {
        final s = v.toString().trim();
        if (s.isNotEmpty) return s;
      }
    }
    return null;
  }

  final secretRaw = str([
    'require-secret',
    'require_secret',
    'requireSecret',
  ])?.toLowerCase();
  final requireSecret = secretRaw == 'true';

  return SkillMetadata(
    homepage: str(['homepage']),
    requireSecret: requireSecret,
    secretDescription: str([
      'require-secret-description',
      'require_secret_description',
      'requireSecretDescription',
    ]),
  );
}

/// Looks for an explicit script name in the body (e.g. `scriptName: "query.html"`
/// or `script name: index.html`). Defaults to `index.html` when none is named.
String _inferScriptName(String body) {
  // Matches an explicit *.html script name only (e.g. scriptName: foo.html |
  // script name: `foo.html` | script_name: foo.html); an extensionless name
  // does not match and falls back to index.html below.
  final match = RegExp(
    r'''script[\s_]?name["`'\s:]+["`']?([A-Za-z0-9._-]+\.html)''',
    caseSensitive: false,
  ).firstMatch(body);
  return match?.group(1) ?? 'index.html';
}
