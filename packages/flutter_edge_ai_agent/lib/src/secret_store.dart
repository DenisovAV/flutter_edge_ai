/// In-memory store for `require-secret` skill credentials (API keys), keyed by
/// [Skill.name].
///
/// SECURITY: secrets are NEVER placed in the model prompt. The agent loop reads
/// a secret from here only at execution time and hands it to the executor as
/// the `secret` argument (for JS skills, the `secret` param of
/// `window.ai_edge_gallery_get_result`). Values live only in memory for the
/// process lifetime; persistence (if any) is the host app's responsibility.
class SecretStore {
  final _secrets = <String, String>{};

  /// Store (or replace) the secret for the skill named [skillName]. An empty
  /// secret clears it instead of storing a blank — so [has], [get], and [set]
  /// agree on "a stored secret is non-empty".
  void set(String skillName, String secret) {
    if (secret.isEmpty) {
      _secrets.remove(skillName);
    } else {
      _secrets[skillName] = secret;
    }
  }

  /// The secret for [skillName], or null if none is set.
  String? get(String skillName) => _secrets[skillName];

  /// Whether a non-empty secret is set for [skillName].
  bool has(String skillName) {
    final v = _secrets[skillName];
    return v != null && v.isNotEmpty;
  }

  /// Remove the secret for [skillName]. No-op if absent.
  void remove(String skillName) => _secrets.remove(skillName);

  /// Drop every stored secret.
  void clear() => _secrets.clear();
}
