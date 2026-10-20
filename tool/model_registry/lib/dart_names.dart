// The Dart names the generated catalogs give registry ids and slugs:
// `gemma-4-e2b-it` is `LiteRtLmModels.gemma4E2bIt`, its slug `npu-sm8750` is
// `.npuSm8750`. Words join in lowerCamelCase; a word that starts with a digit
// after one that ends with a digit is kept apart with `_`, and a `.` is `_`,
// so `qwen3-0.6b` is `qwen3_0_6b` and 2.5 never reads as 25.

/// The lowerCamelCase member name for [id] (a registry id or a slug).
String dartMemberName(String id) {
  final words = [for (final w in id.split('-')) w.replaceAll('.', '_')];
  final out = StringBuffer(words.first);
  for (final word in words.skip(1)) {
    final previous = out.toString();
    final endsWithDigit = _isDigit(previous.codeUnitAt(previous.length - 1));
    final startsWithDigit = _isDigit(word.codeUnitAt(0));
    if (startsWithDigit) {
      out.write(endsWithDigit ? '_$word' : word);
    } else {
      out.write('${word[0].toUpperCase()}${word.substring(1)}');
    }
  }
  return out.toString();
}

/// The UpperCamelCase class name for [id] after [prefix]: `LiteRtLm` and
/// `gemma-4-e2b-it` give `LiteRtLmGemma4E2bIt`.
String dartClassName(String prefix, String id) {
  final member = dartMemberName(id);
  return '$prefix${member[0].toUpperCase()}${member.substring(1)}';
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Why [name] cannot be a generated member name, or null when it can.
/// [taken] are the names it would clash with.
String? dartNameProblem(String name, Set<String> taken) {
  if (!RegExp(r'^[a-z][A-Za-z0-9_]*$').hasMatch(name)) {
    return '"$name" is not a Dart identifier that starts with a letter';
  }
  if (_reserved.contains(name)) return '"$name" is a Dart reserved word';
  if (taken.contains(name)) return '"$name" is taken';
  return null;
}

/// Members of `CatalogModel` and `Object`: a variant getter may not shadow
/// them.
const catalogModelMembers = {
  'id',
  'displayName',
  'family',
  'archClass',
  'parametersB',
  'license',
  'licenseUrl',
  'variants',
  'variantFor',
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
};

/// Static members of a generated namespace class: a model getter may not
/// shadow them.
const catalogNamespaceMembers = {'catalog', 'all', 'byId'};

const _reserved = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'type',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};
