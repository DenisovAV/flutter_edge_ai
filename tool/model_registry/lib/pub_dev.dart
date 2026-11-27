// What an app gets from pub.dev today: the catalog packages' published
// versions and the native build they bundle (model_registry/pub_dev.yaml).
//
// The site describes what a user installs, not the workspace: a cell is
// verified when a run passed on the native build of the published packages.
// flutter_edge_ai_litertlm pins litertlm_dart exactly, and litertlm_dart's
// hook names one native release and one archive per host, so the published
// adapter version decides the native build. The pin is committed, so
// `generate` and `check` never reach the network; `registry.dart pin
// <package>` moves it in a release commit, and `registry.dart pub-check`
// (network, opt-in) compares it with what pub.dev serves.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'check.dart';

const pinFile = 'pub_dev.yaml';

/// The package that pins litertlm_dart, and so the native build.
const adapterPackage = 'flutter_edge_ai_litertlm';

/// The LiteRT-LM archive each native host loads, as named in
/// packages/litertlm_dart/hook/build.dart. The speech package loads the same
/// libraries.
const hostArchives = {
  'android_arm64': 'litertlm-android_arm64.tar.gz',
  'ios_arm64': 'litertlm-ios_arm64.tar.gz',
  'macos_arm64': 'litertlm-macos_arm64.tar.gz',
  'windows_x64': 'litertlm-windows_x86_64.tar.gz',
  'linux_x64': 'litertlm-linux_x86_64.tar.gz',
  'linux_arm64': 'litertlm-linux_arm64.tar.gz',
};

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

/// Host → archive sha256 named by a litertlm_dart hook's source.
Map<String, String> hookArchives(String hookSource) => {
  for (final MapEntry(key: host, value: archive) in hostArchives.entries)
    if (RegExp(
          "'${RegExp.escape(archive)}':\\s*'([0-9a-f]{64})'",
        ).firstMatch(hookSource)
        case final m?)
      host: m.group(1)!,
};

/// The native release tag a litertlm_dart native_release.dart names.
String? nativeReleaseTag(String source) => switch (RegExp(
  r"liteRtLmNativeVersion\s*=\s*'([^']+)'",
).firstMatch(source)) {
  final m? => 'native-v${m.group(1)}',
  null => null,
};

/// model_registry/pub_dev.yaml.
final class PubDevPin {
  PubDevPin({
    required this.packages,
    required this.litertlmDart,
    required this.nativeRelease,
    required this.archives,
  });

  /// Catalog package → its version on pub.dev.
  final Map<String, String> packages;

  /// The litertlm_dart version the published adapter pins.
  final String litertlmDart;

  /// That litertlm_dart's native release tag.
  final String nativeRelease;

  /// Host → the sha256 of the archive that litertlm_dart's hook downloads.
  final Map<String, String> archives;

  /// Host → the native build an app bundles there: the archive's sha256, or
  /// on the web the adapter version, whose JavaScript pins ride with it.
  String? nativeFor(String host) => host == 'web'
      ? switch (packages[adapterPackage]) {
          final v? => '$adapterPackage@$v',
          null => null,
        }
      : archives[host];

  String toYaml() {
    final out = StringBuffer()
      ..writeln('# What an app that resolves the catalog packages from pub.dev')
      ..writeln('# bundles today. The site (registry.md, models.json) counts a')
      ..writeln('# run as verified only on this native build and these minor')
      ..writeln('# versions. Written by `dart run bin/registry.dart pin')
      ..writeln('# <package>` in the release commit of that package; never by')
      ..writeln(
        '# hand. `dart run bin/registry.dart pub-check` compares it with',
      )
      ..writeln('# pub.dev. See README.md, "What pub.dev ships".')
      ..writeln('packages:');
    for (final k in packages.keys.toList()..sort()) {
      out.writeln('  $k: ${packages[k]}');
    }
    out
      ..writeln('litertlm_dart: $litertlmDart')
      ..writeln('native_release: $nativeRelease')
      ..writeln('archives:');
    for (final h in archives.keys.toList()..sort()) {
      out.writeln('  $h: ${archives[h]}');
    }
    return '$out';
  }
}

/// [pinFile] under [registryDir], or null with a problem.
PubDevPin? readPin(Directory registryDir, List<Problem> problems) {
  final file = File(p.join(registryDir.path, pinFile));
  void error(String where, String m) =>
      problems.add(Problem(pinFile, where, m));
  if (!file.existsSync()) {
    error('-', 'missing: the site judges evidence against it');
    return null;
  }
  final Object? raw;
  try {
    raw = loadYaml(file.readAsStringSync());
  } on YamlException catch (e) {
    error('-', 'not YAML: ${e.message}');
    return null;
  }
  if (raw is! YamlMap) {
    error('-', 'not a mapping');
    return null;
  }
  final YamlMap doc = raw;
  for (final k in doc.keys) {
    if (!const {
      'packages',
      'litertlm_dart',
      'native_release',
      'archives',
    }.contains(k)) {
      error('$k', 'unknown key');
    }
  }
  Map<String, String>? strings(String name, {RegExp? values}) {
    final v = doc[name];
    if (v is! YamlMap || v.isEmpty) {
      error(name, 'a non-empty map');
      return null;
    }
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in v.entries) {
      if (values != null && !values.hasMatch('$value')) {
        error('$name.$key', 'malformed "$value"');
      }
      out['$key'] = '$value';
    }
    return out;
  }

  final packages = strings('packages');
  final archives = strings('archives', values: _sha256);
  final litertlmDart = doc['litertlm_dart'];
  final tag = doc['native_release'];
  if (litertlmDart == null) error('litertlm_dart', 'required');
  if (tag is! String || !tag.startsWith('native-v')) {
    error('native_release', 'a native-v<version> tag');
  }
  if (packages != null && !packages.containsKey(adapterPackage)) {
    error('packages', 'needs $adapterPackage: it pins the native build');
  }
  if (packages == null ||
      archives == null ||
      litertlmDart == null ||
      tag is! String) {
    return null;
  }
  return PubDevPin(
    packages: packages,
    litertlmDart: '$litertlmDart',
    nativeRelease: tag,
    archives: archives,
  );
}

/// What the workspace's litertlm_dart names: its version, native tag and
/// archives. Null when the workspace has no litertlm_dart.
({String version, String? tag, Map<String, String> archives})?
workspaceLitertlmDart(String repoRoot) {
  final dir = p.join(repoRoot, 'packages', 'litertlm_dart');
  final pubspec = File(p.join(dir, 'pubspec.yaml'));
  final hook = File(p.join(dir, 'hook', 'build.dart'));
  if (!pubspec.existsSync() || !hook.existsSync()) return null;
  final release = File(
    p.join(dir, 'lib', 'src', 'runtime', 'native_release.dart'),
  );
  return (
    version: '${(loadYaml(pubspec.readAsStringSync()) as YamlMap)['version']}',
    tag: release.existsSync()
        ? nativeReleaseTag(release.readAsStringSync())
        : null,
    archives: hookArchives(hook.readAsStringSync()),
  );
}

/// Problems with [pin] that need no network: a host it names no archive for,
/// a package with a catalog it leaves out, and, when the workspace's
/// litertlm_dart is the pinned version, any tag or archive that differs from
/// the workspace's (the hook moved without a version bump, or a hand edit).
void checkPin(
  PubDevPin pin,
  String repoRoot,
  Iterable<String> hosts,
  Iterable<String> catalogPackages,
  List<Problem> problems,
) {
  void error(String where, String m) =>
      problems.add(Problem(pinFile, where, m));
  for (final h in hosts) {
    if (pin.nativeFor(h) == null) {
      error(
        'archives',
        'no native build for host $h: every run there would '
            'read as stale',
      );
    }
  }
  for (final package in catalogPackages) {
    if (!pin.packages.containsKey(package)) {
      error('packages', '$package ships a catalog and has no version here');
    }
  }
  final ws = workspaceLitertlmDart(repoRoot);
  if (ws == null || ws.version != pin.litertlmDart) return;
  if (ws.tag != pin.nativeRelease) {
    error(
      'native_release',
      '${pin.nativeRelease}, but litertlm_dart '
          '${ws.version} in the workspace names ${ws.tag}',
    );
  }
  for (final MapEntry(key: host, value: sha) in pin.archives.entries) {
    if (ws.archives[host] != sha) {
      error(
        'archives.$host',
        'differs from litertlm_dart ${ws.version}\'s '
            'hook (${ws.archives[host]})',
      );
    }
  }
}

/// The pin after a release of [package] at the workspace's version. For the
/// adapter, also the litertlm_dart it pins and that package's native build,
/// which must be the workspace's. Throws [StateError] naming what is wrong.
PubDevPin movePin(PubDevPin? pin, String repoRoot, String package) {
  final pubspec = File(p.join(repoRoot, 'packages', package, 'pubspec.yaml'));
  if (!pubspec.existsSync()) throw StateError('no packages/$package');
  final yaml = loadYaml(pubspec.readAsStringSync()) as YamlMap;
  final packages = {...?pin?.packages, package: '${yaml['version']}'};
  if (package != adapterPackage) {
    if (pin == null) {
      throw StateError('no $pinFile yet: pin $adapterPackage first');
    }
    return PubDevPin(
      packages: packages,
      litertlmDart: pin.litertlmDart,
      nativeRelease: pin.nativeRelease,
      archives: pin.archives,
    );
  }
  final dep = (yaml['dependencies'] as YamlMap?)?['litertlm_dart'];
  if (dep is! String || !RegExp(r'^\d+\.\d+\.\d+(\+\d+)?$').hasMatch(dep)) {
    throw StateError(
      '$package must pin litertlm_dart to one version, not "$dep"',
    );
  }
  final ws = workspaceLitertlmDart(repoRoot);
  if (ws == null || ws.version != dep || ws.tag == null) {
    throw StateError(
      '$package pins litertlm_dart $dep, but the workspace has '
      '${ws?.version ?? 'none'}: release litertlm_dart $dep first',
    );
  }
  return PubDevPin(
    packages: packages,
    litertlmDart: dep,
    nativeRelease: ws.tag!,
    archives: ws.archives,
  );
}

/// `pub-check`: [pin] against pub.dev. Returns the disagreements; empty when
/// every pinned package is pub.dev's latest, the latest adapter pins the
/// pinned litertlm_dart, and that litertlm_dart's published hook names the
/// pinned tag and archives.
Future<List<String>> pubCheck(
  PubDevPin pin, {
  Uri? base,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final root = base ?? Uri.parse('https://pub.dev');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  Future<List<int>> get(Uri uri) async {
    final req = await client.getUrl(uri).timeout(timeout);
    final res = await req.close().timeout(timeout);
    final bytes = await res
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(timeout);
    if (res.statusCode != 200) {
      throw HttpException('${res.statusCode} for $uri');
    }
    return bytes;
  }

  Future<Map<String, Object?>> json(String path) async =>
      jsonDecode(utf8.decode(await get(root.resolve(path))))
          as Map<String, Object?>;

  final out = <String>[];
  try {
    for (final MapEntry(key: package, value: version) in pin.packages.entries) {
      final latest =
          (await json('/api/packages/$package'))['latest']!
              as Map<String, Object?>;
      if (latest['version'] != version) {
        out.add('$package: pinned $version, pub.dev has ${latest['version']}');
      }
      if (package == adapterPackage) {
        final dep =
            ((latest['pubspec']! as Map)['dependencies']
                as Map?)?['litertlm_dart'];
        if ('$dep' != pin.litertlmDart) {
          out.add(
            '$package ${latest['version']} on pub.dev pins litertlm_dart '
            '$dep, the pin says ${pin.litertlmDart}',
          );
        }
      }
    }
    final info = await json(
      '/api/packages/litertlm_dart/versions/'
      '${Uri.encodeComponent(pin.litertlmDart)}',
    );
    final files = untarGz(await get(Uri.parse(info['archive_url']! as String)));
    final hook = files['hook/build.dart'];
    final release = files['lib/src/runtime/native_release.dart'];
    if (hook == null || release == null) {
      out.add(
        'litertlm_dart ${pin.litertlmDart} on pub.dev has no hook or '
        'native_release.dart',
      );
    } else {
      final tag = nativeReleaseTag(utf8.decode(release));
      if (tag != pin.nativeRelease) {
        out.add(
          'litertlm_dart ${pin.litertlmDart} on pub.dev names $tag, '
          'the pin says ${pin.nativeRelease}',
        );
      }
      final archives = hookArchives(utf8.decode(hook));
      for (final host in {...archives.keys, ...pin.archives.keys}) {
        if (archives[host] != pin.archives[host]) {
          out.add(
            'archives.$host: pub.dev ${archives[host]}, the pin '
            '${pin.archives[host]}',
          );
        }
      }
    }
  } finally {
    client.close(force: true);
  }
  return out;
}

/// The regular files of a .tar.gz, by path.
Map<String, List<int>> untarGz(List<int> bytes) {
  final tar = gzip.decode(bytes);
  final out = <String, List<int>>{};
  var at = 0;
  while (at + 512 <= tar.length) {
    final header = tar.sublist(at, at + 512);
    if (header.every((b) => b == 0)) break;
    String field(int from, int len) {
      final raw = header.sublist(from, from + len);
      final end = raw.indexOf(0);
      return ascii.decode(end < 0 ? raw : raw.sublist(0, end)).trim();
    }

    var name = field(0, 100);
    final prefix = field(345, 155);
    if (prefix.isNotEmpty) name = '$prefix/$name';
    final size = int.parse(
      field(124, 12).isEmpty ? '0' : field(124, 12),
      radix: 8,
    );
    final type = header[156];
    at += 512;
    if (type == 0x30 || type == 0) {
      out[name.startsWith('./') ? name.substring(2) : name] = tar.sublist(
        at,
        at + size,
      );
    }
    at += (size + 511) ~/ 512 * 512;
  }
  return out;
}
