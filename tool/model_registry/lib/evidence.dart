// Evidence: what a recorded run proved, and against which native build.
//
// An integration test that passed prints one line per check:
//
//   FEA_EVIDENCE v1 {"variant": "...", "host": "...", "backend": "...", "check": "..."}
//
// (packages/flutter_edge_ai/example/integration_test/registry_evidence.dart).
// `registry.dart evidence` reads a run's log and writes one
// model_registry/evidence/<date>_<host>_<device>.json. A cell is verified
// while the run's native build is the one the package ships for that host,
// and stale after it moves.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'check.dart';

const evidencePrefix = 'FEA_EVIDENCE v1 ';

/// The LiteRT-LM archive each native host loads, as named in
/// packages/flutter_edge_ai_litertlm/hook/build.dart. The speech package
/// loads the same libraries.
const _archives = {
  'android_arm64': 'litertlm-android_arm64.tar.gz',
  'ios_arm64': 'litertlm-ios_arm64.tar.gz',
  'macos_arm64': 'litertlm-macos_arm64.tar.gz',
  'windows_x64': 'litertlm-windows_x86_64.tar.gz',
  'linux_x64': 'litertlm-linux_x86_64.tar.gz',
  'linux_arm64': 'litertlm-linux_arm64.tar.gz',
};

/// What a run of [host] ran against: the sha256 of the host's native archive,
/// or on the web the litertlm package version, whose JavaScript pins ride
/// with it. Null when the hook does not name an archive for [host].
String? nativeKey(String repoRoot, String host, Map<String, String> versions) {
  if (host == 'web') {
    final v = versions['flutter_edge_ai_litertlm'];
    return v == null ? null : 'flutter_edge_ai_litertlm@$v';
  }
  final archive = _archives[host];
  if (archive == null) return null;
  final hook = File(
    p.join(
      repoRoot,
      'packages',
      'flutter_edge_ai_litertlm',
      'hook',
      'build.dart',
    ),
  );
  if (!hook.existsSync()) return null;
  final m = RegExp(
    "'${RegExp.escape(archive)}':\\s*'([0-9a-f]{64})'",
  ).firstMatch(hook.readAsStringSync());
  return m?.group(1);
}

/// One evidence file: a run on one host.
final class EvidenceRun {
  EvidenceRun({
    required this.file,
    required this.date,
    required this.host,
    required this.device,
    required this.commit,
    required this.packages,
    required this.native,
    required this.logSha256,
    required this.logUrl,
    required this.cells,
  });

  /// The file's name under evidence/.
  final String file;
  final String date;
  final String host;
  final String device;
  final String commit;

  /// Package → version at [commit].
  final Map<String, String> packages;

  /// [nativeKey] at [commit].
  final String native;
  final String logSha256;
  final String? logUrl;

  /// Variant id → backend → the checks that passed.
  final Map<String, Map<String, List<String>>> cells;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'date': date,
    'host': host,
    'device': device,
    'commit': commit,
    'packages': packages,
    'native': native,
    'log_sha256': logSha256,
    'log_url': logUrl,
    'cells': {
      for (final MapEntry(key: v, value: byBackend)
          in (cells.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
        v: {
          for (final MapEntry(key: b, value: checks) in byBackend.entries)
            b: (checks.toSet().toList()..sort()),
        },
    },
  };

  static EvidenceRun? fromJson(
    String file,
    Object? json,
    void Function(String) error,
  ) {
    if (json is! Map<String, Object?>) {
      error('not a JSON object');
      return null;
    }
    const keys = {
      'schema_version',
      'date',
      'host',
      'device',
      'commit',
      'packages',
      'native',
      'log_sha256',
      'log_url',
      'cells',
    };
    for (final k in json.keys) {
      if (!keys.contains(k)) error('unknown key "$k"');
    }
    String? str(String key, RegExp? pattern) {
      final v = json[key];
      if (v is! String || (pattern != null && !pattern.hasMatch(v))) {
        error('$key: ${v is String ? 'malformed "$v"' : 'required'}');
        return null;
      }
      return v;
    }

    if (json['schema_version'] != 1) error('schema_version must be 1');
    final date = str('date', RegExp(r'^\d{4}-\d{2}-\d{2}$'));
    final host = str('host', null);
    final device = str('device', RegExp(r'\S'));
    final commit = str('commit', RegExp(r'^[0-9a-f]{40}$'));
    final native = str('native', null);
    final logSha = str('log_sha256', RegExp(r'^[0-9a-f]{64}$'));
    final logUrl = json['log_url'];
    if (logUrl != null &&
        (logUrl is! String || !logUrl.startsWith('https://'))) {
      error('log_url must be null or an https URL');
    }
    final packages = json['packages'];
    if (packages is! Map<String, Object?> ||
        packages.values.any((v) => v is! String)) {
      error('packages: a map of package to version');
    }
    final cells = <String, Map<String, List<String>>>{};
    final rawCells = json['cells'];
    if (rawCells is! Map<String, Object?> || rawCells.isEmpty) {
      error('cells: a non-empty map of variant to backend to checks');
    } else {
      for (final MapEntry(key: v, value: byBackend) in rawCells.entries) {
        if (byBackend is! Map<String, Object?>) {
          error('cells.$v: a map of backend to checks');
          continue;
        }
        cells[v] = {
          for (final MapEntry(key: b, value: checks) in byBackend.entries)
            if (checks is List &&
                checks.isNotEmpty &&
                checks.every((c) => c is String))
              b: checks.cast<String>()
            else
              b: () {
                error('cells.$v.$b: a non-empty list of check names');
                return const <String>[];
              }(),
        };
      }
    }
    if ([date, host, device, commit, native, logSha].contains(null) ||
        packages is! Map<String, Object?>) {
      return null;
    }
    return EvidenceRun(
      file: file,
      date: date!,
      host: host!,
      device: device!,
      commit: commit!,
      packages: packages.cast<String, String>(),
      native: native!,
      logSha256: logSha!,
      logUrl: logUrl as String?,
      cells: cells,
    );
  }
}

/// Every run under `<registry>/evidence/`, oldest first.
List<EvidenceRun> readEvidence(Directory registryDir, List<Problem> problems) {
  final dir = Directory(p.join(registryDir.path, 'evidence'));
  if (!dir.existsSync()) return const [];
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final runs = <EvidenceRun>[];
  for (final f in files) {
    final name = p.basename(f.path);
    void error(String m) => problems.add(Problem('evidence/$name', '-', m));
    Object? json;
    try {
      json = jsonDecode(f.readAsStringSync());
    } on FormatException catch (e) {
      error('not JSON: ${e.message}');
      continue;
    }
    final run = EvidenceRun.fromJson(name, json, error);
    if (run != null) runs.add(run);
  }
  return runs;
}

/// What one log line says passed.
typedef EvidenceLine = ({
  String variant,
  String host,
  String backend,
  String check,
  bool simulator,
});

/// The FEA_EVIDENCE lines of [log]; a malformed one is reported by line.
List<EvidenceLine> parseEvidenceLog(
  String log,
  void Function(int line, String message) error,
) {
  final out = <EvidenceLine>[];
  final lines = const LineSplitter().convert(log);
  for (final (i, line) in lines.indexed) {
    final at = line.indexOf(evidencePrefix);
    if (at < 0) continue;
    Object? json;
    try {
      json = jsonDecode(line.substring(at + evidencePrefix.length).trim());
    } on FormatException catch (e) {
      error(i + 1, 'not JSON: ${e.message}');
      continue;
    }
    if (json case {
      'variant': final String variant,
      'host': final String host,
      'backend': final String backend,
      'check': final String check,
    }) {
      out.add((
        variant: variant,
        host: host,
        backend: backend,
        check: check,
        simulator: json['simulator'] == true,
      ));
    } else {
      error(i + 1, 'needs variant, host, backend and check');
    }
  }
  return out;
}

/// sha256 of [bytes], hex.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Turns the evidence lines of one run into a run, or reports why not: lines
/// from more than one host, a simulator, or no lines at all.
EvidenceRun? runFromLines(
  List<EvidenceLine> lines, {
  required String file,
  required String date,
  required String device,
  required String commit,
  required Map<String, String> packages,
  required String? native,
  required String logSha256,
  required String? logUrl,
  required void Function(String) error,
}) {
  if (lines.isEmpty) {
    error('no "$evidencePrefix" line in the log');
    return null;
  }
  final hosts = {for (final l in lines) l.host};
  if (hosts.length != 1) {
    error('one run is one host; the log has ${hosts.join(', ')}');
    return null;
  }
  if (lines.any((l) => l.simulator)) {
    error('a simulator is not the host it reports; run on the device');
    return null;
  }
  if (native == null) {
    error('no native build named for host ${hosts.single}');
    return null;
  }
  final cells = <String, Map<String, List<String>>>{};
  for (final l in lines) {
    (cells.putIfAbsent(l.variant, () => {}).putIfAbsent(l.backend, () => []))
        .add(l.check);
  }
  return EvidenceRun(
    file: file,
    date: date,
    host: hosts.single,
    device: device,
    commit: commit,
    packages: packages,
    native: native,
    logSha256: logSha256,
    logUrl: logUrl,
    cells: cells,
  );
}
