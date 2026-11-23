// The hook's defines under both keys: `hooks.user_defines.litertlm_dart`
// (what the hooks framework hands this hook) and, for apps written before the
// hook moved here, `hooks.user_defines.flutter_edge_ai_litertlm`.
//
// The framework hands a hook only its own package's defines, so the old key is
// read from the pubspec the framework read them from: the workspace root, the
// directory whose `.dart_tool/hooks_runner/` holds this hook's shared output
// directory. A value under the new key wins; one taken from the old key is
// said on stderr, once per key. To be removed with the next upstream
// LiteRT-LM version.

import 'dart:io';

import 'package:yaml/yaml.dart';

/// The package whose `user_defines` key this hook still reads.
const legacyUserDefinesPackage = 'flutter_edge_ai_litertlm';

/// The workspace pubspec above [outputDirectoryShared] (the hook input's
/// shared output directory, `<root>/.dart_tool/hooks_runner/shared/…`), or
/// null when the directory is not laid out that way or the root has no
/// pubspec.yaml.
File? workspacePubspecFor(Uri outputDirectoryShared) {
  final segments = outputDirectoryShared.pathSegments;
  for (var i = segments.length - 2; i >= 0; i--) {
    if (segments[i] != '.dart_tool' || segments[i + 1] != 'hooks_runner') {
      continue;
    }
    final root = outputDirectoryShared.replace(
      pathSegments: [...segments.take(i), 'pubspec.yaml'],
    );
    final file = File.fromUri(root);
    return file.existsSync() ? file : null;
  }
  return null;
}

/// `hooks.user_defines.<package>` in [pubspecYaml], or an empty map.
Map<String, Object?> userDefinesIn(String pubspecYaml, String package) {
  final Object? doc;
  try {
    doc = loadYaml(pubspecYaml);
  } on YamlException {
    return const {};
  }
  final defines = switch (doc) {
    {'hooks': {'user_defines': final Map<Object?, Object?> all}} =>
      all[package],
    _ => null,
  };
  if (defines is! Map<Object?, Object?>) return const {};
  return {
    for (final MapEntry(:key, :value) in defines.entries)
      if (key is String) key: _plain(value),
  };
}

Object? _plain(Object? value) => switch (value) {
  final YamlList list => [for (final v in list) _plain(v)],
  final YamlMap map => {
    for (final MapEntry(:key, :value) in map.entries) '$key': _plain(value),
  },
  _ => value,
};

/// The hook's defines: the current key's, then the legacy key's.
final class HookDefines {
  HookDefines({
    required this._current,
    required this._currentPath,
    this._legacy = const {},
    this._legacyBase,
    void Function(String message)? warn,
  }) : _warn = warn ?? stderr.writeln;

  final Object? Function(String key) _current;
  final Uri? Function(String key) _currentPath;
  final Map<String, Object?> _legacy;
  final Uri? _legacyBase;
  final void Function(String message) _warn;
  final Set<String> _warned = {};

  /// The value of [key], from the current key when it sets it.
  Object? operator [](String key) {
    final value = _current(key);
    if (value != null) return value;
    if (!_legacy.containsKey(key)) return null;
    _said(key);
    return _legacy[key];
  }

  /// The `user_defines` package key [key]'s value comes from: litertlm_dart's
  /// own, or [legacyUserDefinesPackage] when only that one sets it.
  String packageOf(String key) =>
      _current(key) == null && _legacy.containsKey(key)
      ? legacyUserDefinesPackage
      : 'litertlm_dart';

  /// [key]'s value as a path, resolved against the pubspec that set it.
  Uri? path(String key) {
    final value = _currentPath(key);
    if (value != null) return value;
    final legacy = _legacy[key];
    if (legacy is! String || _legacyBase == null) return null;
    _said(key);
    return _legacyBase.resolveUri(Uri.file(legacy));
  }

  void _said(String key) {
    if (!_warned.add(key)) return;
    _warn(
      '[litertlm_dart] hooks.user_defines.$legacyUserDefinesPackage.$key is '
      'read for now; move it to hooks.user_defines.litertlm_dart.$key in the '
      "app's (or workspace root's) pubspec.yaml.",
    );
  }
}
