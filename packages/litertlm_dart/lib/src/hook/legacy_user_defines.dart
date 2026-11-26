// The hook's defines: `hooks.user_defines.litertlm_dart`, what the hooks
// framework hands this hook. Up to litertlm_dart 0.19.1+4 the hook also read,
// with a warning, the key apps used before it moved here,
// `hooks.user_defines.flutter_edge_ai_litertlm`, until the next upstream
// LiteRT-LM version. From 0.20.0 a define still under the old key fails the
// build and names the new key: dropping it silently would turn an app's NPU
// opt-ins off without a word.
//
// The framework hands a hook only its own package's defines, so the old key is
// read from the pubspec the framework read them from: the workspace root, the
// directory whose `.dart_tool/hooks_runner/` holds this hook's shared output
// directory.

import 'dart:io';

import 'package:yaml/yaml.dart';

import 'macos_companions.dart' show macOSCompanionsDefine;

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

/// Why the build stops when [legacy] (the defines under
/// [legacyUserDefinesPackage] in [pubspec]) is not empty; null when it is.
///
/// Each define is to be moved to `litertlm_dart:`, except
/// [macOSCompanionsDefine], which no release reads any more: that one is to
/// be deleted.
String? legacyUserDefinesRefusal(Map<String, Object?> legacy, String pubspec) {
  if (legacy.isEmpty) return null;
  final keys = legacy.keys.toList()..sort();
  final move = [
    for (final k in keys)
      if (k != macOSCompanionsDefine) k,
  ];
  final obsolete = keys.contains(macOSCompanionsDefine);
  return [
    'litertlm_dart: $pubspec sets ${keys.map((k) => 'hooks.user_defines.'
            '$legacyUserDefinesPackage.$k').join(', ')}. That key is no longer '
        'read (since litertlm_dart 0.20.0).',
    if (move.isNotEmpty)
      'Move ${move.length == 1 ? '${_old(move.single)}' : 'the others'} to '
          'hooks.user_defines.litertlm_dart '
          '(${move.map((k) => 'litertlm_dart: $k').join(', ')}) in the same '
          'pubspec.yaml.',
    if (obsolete)
      'Delete ${_old(macOSCompanionsDefine)}: it is obsolete, macOS needs no '
          'companion library any more.',
  ].join(' ');
}

String _old(String key) => 'hooks.user_defines.$legacyUserDefinesPackage.$key';

/// The hook's defines, from `hooks.user_defines.litertlm_dart`.
final class HookDefines {
  HookDefines({required this._current, required this._currentPath});

  final Object? Function(String key) _current;
  final Uri? Function(String key) _currentPath;

  /// The value of [key].
  Object? operator [](String key) => _current(key);

  /// The `user_defines` package key [key]'s value comes from (for errors).
  String packageOf(String key) => 'litertlm_dart';

  /// [key]'s value as a path, resolved against the pubspec that set it.
  Uri? path(String key) => _currentPath(key);
}
