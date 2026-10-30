// Runs the release gate (native/litert_lm/check_embedding_exports.py) itself
// on fixture bundles: its main(), not a copy of its rules. The libraries in a
// fixture are empty files, and the driver replaces the gate's export-table
// reader with a table per file name, so the test needs python3 and nothing
// else. It holds the LiteRT C library rule of #747: the functions
// LiteRtBindings looks up are read from libLiteRt.so on Linux and LiteRt.dll
// on Windows, chosen by the platform in the bundle's label, and from
// libLiteRtLm elsewhere; any one missing fails the gate.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _gate = 'native/litert_lm/check_embedding_exports.py';

/// Imports the gate, gives each fixture library the export table named in
/// argv[3] (a JSON map of file name to a table: `main` is every symbol the
/// gate wants from the main library, `litert` adds the LiteRT C functions,
/// and a `:SYMBOL` suffix removes that one), runs its main on argv[1] with
/// label argv[2] and prints the exit code last.
const _driver = r'''
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[4])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
main_symbols = set(gate.REQUIRED + gate.SCORING_SYMBOLS
                   + gate.THINKING_BUDGET_SYMBOLS + gate.OWN_BUILD_SYMBOLS)
tables = json.loads(sys.argv[3])
def exports(path):
    spec = tables[os.path.basename(path)]
    names = set(main_symbols)
    if spec.startswith("litert"):
        names |= set(gate.LITERT_BINDINGS_SYMBOLS)
    if ":" in spec:
        names.discard(spec.split(":", 1)[1])
    return names
gate.exports = exports
print("rc=%d" % gate.main(["gate", sys.argv[1], sys.argv[2]]))
''';

Future<(int, String)> _runGate(
  String label,
  Map<String, String> libraries,
) async {
  final bundle = await Directory.systemTemp.createTemp('gate-');
  try {
    for (final name in libraries.keys) {
      File('${bundle.path}/$name').writeAsBytesSync(const []);
    }
    final result = await Process.run('python3', [
      '-I',
      '-c',
      _driver,
      bundle.path,
      label,
      jsonEncode(libraries),
      File(_gate).absolute.path,
    ]);
    final out = '${result.stdout}${result.stderr}';
    final rc = RegExp(r'rc=(\d+)').allMatches(out).lastOrNull?.group(1);
    expect(rc, isNotNull, reason: out);
    return (int.parse(rc!), out);
  } finally {
    bundle.deleteSync(recursive: true);
  }
}

bool _hasPython() {
  try {
    return Process.runSync('python3', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  // Skipped only off CI: on CI a missing python3 must fail, not hide the gate.
  final hasPython = _hasPython();
  final skip = hasPython || Platform.environment.containsKey('CI')
      ? false
      : 'python3 is not on PATH';

  test('python3 is available where the gate must run', () {
    expect(hasPython, isTrue, reason: 'CI must run the release-gate tests');
  }, skip: skip);

  // Main-library symbols only ("main"), or those plus the LiteRT C functions
  // LiteRtBindings looks up ("litert"); ":<symbol>" removes one.
  group('the LiteRT C library LiteRtBindings opens', () {
    test('Linux: libLiteRt.so exporting all of them passes', () async {
      final (rc, out) = await _runGate('litertlm-linux_x86_64', {
        'libLiteRtLm.so': 'main',
        'libLiteRt.so': 'litert',
      });
      expect(rc, 0, reason: out);
      expect(out, contains('libLiteRt.so exports all'));
    });

    test('Linux: libLiteRt.so missing one fails, naming it', () async {
      final (rc, out) = await _runGate('litertlm-linux_x86_64', {
        'libLiteRtLm.so': 'main',
        'libLiteRt.so': 'litert:LiteRtAddOpaqueOptions',
      });
      expect(rc, 1, reason: out);
      expect(out, contains('[FAIL]'));
      expect(out, contains('LiteRtAddOpaqueOptions'));
    });

    test(
      'Linux: no libLiteRt.so fails even when libLiteRtLm has them',
      () async {
        final (rc, out) = await _runGate('litertlm-linux_arm64', {
          'libLiteRtLm.so': 'litert',
        });
        expect(rc, 1, reason: out);
        expect(out, contains('libLiteRt.so'));
      },
    );

    test('Windows: LiteRt.dll missing one fails', () async {
      final (rc, out) = await _runGate('litertlm-windows_x86_64', {
        'LiteRtLm.dll': 'main',
        'LiteRt.dll': 'litert:LiteRtDestroyOpaqueOptions',
      });
      expect(rc, 1, reason: out);
      expect(out, contains('LiteRtDestroyOpaqueOptions'));
    });

    test('Windows: LiteRt.dll exporting all of them passes', () async {
      final (rc, out) = await _runGate('litertlm-windows_x86_64', {
        'LiteRtLm.dll': 'main',
        'LiteRt.dll': 'litert',
      });
      expect(rc, 0, reason: out);
      expect(out, contains('LiteRt.dll exports all'));
    });

    test('the main library missing one of its own functions fails', () async {
      final (rc, out) = await _runGate('litertlm-linux_x86_64', {
        'libLiteRtLm.so': 'main:litert_lm_clear_last_error',
        'libLiteRt.so': 'litert',
      });
      expect(rc, 1, reason: out);
      expect(out, contains('litert_lm_clear_last_error'));
    });

    test('a label that names no platform is refused', () async {
      final (rc, out) = await _runGate('bundle-x', {
        'libLiteRtLm.so': 'litert',
      });
      expect(rc, 1, reason: out);
      expect(out, contains('names no platform'));
    });

    for (final label in [
      'litertlm-ios_arm64',
      'litertlm-ios_sim_arm64',
      'litertlm-macos_arm64',
    ]) {
      test('$label: libLiteRtLm.dylib exporting all of them passes', () async {
        final (rc, out) = await _runGate(label, {
          'libLiteRtLm.dylib': 'litert',
        });
        expect(rc, 0, reason: out);
        expect(out, contains('libLiteRtLm.dylib exports all'));
      });

      test('$label: libLiteRtLm.dylib missing one fails', () async {
        final (rc, out) = await _runGate(label, {
          'libLiteRtLm.dylib': 'litert:LiteRtAddOpaqueOptions',
        });
        expect(rc, 1, reason: out);
        expect(out, contains('LiteRtAddOpaqueOptions'));
      });
    }

    test('Android: libLiteRtLm exporting all of them passes', () async {
      final (rc, out) = await _runGate('litertlm-android_arm64', {
        'libLiteRtLm.so': 'litert',
      });
      expect(rc, 0, reason: out);
    });

    test('Android: libLiteRtLm missing one fails', () async {
      final (rc, out) = await _runGate('litertlm-android_arm64', {
        'libLiteRtLm.so': 'litert:LiteRtCreateOpaqueOptions',
      });
      expect(rc, 1, reason: out);
      expect(out, contains('LiteRtCreateOpaqueOptions'));
    });
  }, skip: skip);
}
