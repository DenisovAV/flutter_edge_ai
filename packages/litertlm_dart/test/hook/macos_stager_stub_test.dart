// The no-op that replaces the macOS companion stager the pasted Podfile block
// runs (lib/src/hook/macos_stager_stub.dart).
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/src/hook/macos_stager_stub.dart';
import 'package:test/test.dart';

/// litertlm_dart 0.19.1+4's tool/stage_macos_companions.sh, as the hook of
/// that release left it in the cache.
final _oldStager = File(
  'test/hook/fixtures/stage_macos_companions_0_19_1_4.sh',
).readAsStringSync();

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('macos_stager_stub');
    file = File('${dir.path}/macos_arm64/$macOSStagerFileName');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('is written where none was, and runs as the Podfile block runs it: '
      'sh, the app\'s Frameworks, exit 0, one line naming the block', () {
    expect(writeMacOSStagerStub(file, '0.20.0'), isTrue);
    expect(file.readAsStringSync(), macOSStagerStub('0.20.0'));
    final frameworks = Directory('${dir.path}/a.app/Contents/Frameworks')
      ..createSync(recursive: true);
    final r = Process.runSync('sh', [file.path, frameworks.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(
      '${r.stdout}'.trim(),
      "litertlm_dart 0.20.0: macOS no longer needs this build phase; you can "
      "remove the '[flutter_gemma] Setup LiteRT-LM macOS' block from your "
      'Podfile',
    );
    expect(frameworks.listSync(), isEmpty, reason: 'it staged something');
  }, skip: Platform.isWindows ? 'no sh' : false);

  test('is executable', () {
    writeMacOSStagerStub(file, '0.20.0');
    final r = Process.runSync(file.path, [dir.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  }, skip: Platform.isWindows ? 'no file modes' : false);

  test('replaces the 0.19.1+4 stager, and a stub of another version', () {
    expect(isOurMacOSStager(_oldStager), isTrue);
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_oldStager);
    expect(writeMacOSStagerStub(file, '0.20.0'), isTrue);
    expect(file.readAsStringSync(), macOSStagerStub('0.20.0'));
    expect(writeMacOSStagerStub(file, '0.20.0+1'), isTrue);
    expect(file.readAsStringSync(), macOSStagerStub('0.20.0+1'));
  });

  test('leaves any other file alone', () {
    const foreign = '#!/bin/sh\necho mine\n';
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(foreign);
    expect(writeMacOSStagerStub(file, '0.20.0'), isFalse);
    expect(file.readAsStringSync(), foreign);
  });

  test('the hook writes it on every macOS build, at the arm64 path the '
      'block names', () {
    final hook = File('hook/build.dart').readAsStringSync();
    expect(
      hook,
      contains('if (os == OS.macOS) _replaceMacOSStager(input, output);'),
    );
    expect(
      hook,
      contains("('flutter_gemma')}/macos_arm64/\$macOSStagerFileName"),
    );
  });
}
