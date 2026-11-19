// The hook still reads the user_defines key apps set before it moved to
// litertlm_dart (`flutter_edge_ai_litertlm:`), from the workspace pubspec the
// hooks framework read the current key from.

import 'dart:io';

import 'package:litertlm_dart/src/hook/legacy_user_defines.dart';
import 'package:test/test.dart';

void main() {
  group('workspacePubspecFor', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('legacy_defines'));
    tearDown(() => root.deleteSync(recursive: true));

    Uri sharedDir(String base) => Uri.directory(
      '$base/.dart_tool/hooks_runner/shared/litertlm_dart/build/',
    );

    test('is the pubspec beside the .dart_tool holding hooks_runner', () {
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: app\n');
      expect(
        workspacePubspecFor(sharedDir(root.path))?.path,
        File('${root.path}/pubspec.yaml').path,
      );
    });

    test('is null without that layout or without a pubspec there', () {
      expect(workspacePubspecFor(sharedDir(root.path)), isNull);
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: app\n');
      expect(
        workspacePubspecFor(Uri.directory('${root.path}/elsewhere/out/')),
        isNull,
      );
      // A .dart_tool the hooks runner does not own (build_runner's).
      expect(
        workspacePubspecFor(
          Uri.directory('${root.path}/.dart_tool/build/generated/'),
        ),
        isNull,
      );
    });
  });

  group('userDefinesIn', () {
    test('reads the package block, nested values as plain Dart', () {
      const yaml = '''
name: app
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
      qualcomm_npu_aar: third_party/qnn.aar
      list: [a, b]
    other:
      qualcomm_npu: false
''';
      expect(userDefinesIn(yaml, 'flutter_edge_ai_litertlm'), {
        'qualcomm_npu': true,
        'qualcomm_npu_aar': 'third_party/qnn.aar',
        'list': ['a', 'b'],
      });
    });

    test('is empty without the block, or for YAML it cannot read', () {
      expect(userDefinesIn('name: app\n', 'flutter_edge_ai_litertlm'), {});
      expect(
        userDefinesIn(
          'hooks:\n  user_defines: 3\n',
          'flutter_edge_ai_litertlm',
        ),
        {},
      );
      expect(userDefinesIn('a: [', 'flutter_edge_ai_litertlm'), {});
    });
  });

  group('HookDefines', () {
    late List<String> warned;

    HookDefines defines({
      Map<String, Object?> current = const {},
      Map<String, Object?> legacy = const {},
    }) => HookDefines(
      current: (key) => current[key],
      currentPath: (key) => switch (current[key]) {
        final String path => Uri.file('/app/$path'),
        _ => null,
      },
      legacy: legacy,
      legacyBase: Uri.directory('/workspace/'),
      warn: warned.add,
    );

    setUp(() => warned = []);

    test('the current key wins, and nothing is said', () {
      final d = defines(
        current: {'qualcomm_npu': false},
        legacy: {'qualcomm_npu': true},
      );
      expect(d['qualcomm_npu'], isFalse);
      expect(warned, isEmpty);
    });

    test('a value only under the old key is used and said once', () {
      final d = defines(legacy: {'qualcomm_npu': true});
      expect(d['qualcomm_npu'], isTrue);
      expect(d['qualcomm_npu'], isTrue);
      expect(warned, hasLength(1));
      expect(
        warned.single,
        allOf(
          contains('hooks.user_defines.flutter_edge_ai_litertlm.qualcomm_npu'),
          contains('hooks.user_defines.litertlm_dart.qualcomm_npu'),
        ),
      );
    });

    test('a key set under neither is null', () {
      expect(defines()['mediatek_npu'], isNull);
      expect(defines().path('qualcomm_npu_aar'), isNull);
      expect(warned, isEmpty);
    });

    test('a path under the old key resolves against its pubspec', () {
      final d = defines(legacy: {'qualcomm_npu_aar': 'third_party/qnn.aar'});
      expect(
        d.path('qualcomm_npu_aar'),
        Uri.file('/workspace/third_party/qnn.aar'),
      );
      expect(warned, hasLength(1));
    });

    test('a path under the current key wins', () {
      final d = defines(
        current: {'qualcomm_npu_aar': 'mine.aar'},
        legacy: {'qualcomm_npu_aar': 'old.aar'},
      );
      expect(d.path('qualcomm_npu_aar'), Uri.file('/app/mine.aar'));
      expect(warned, isEmpty);
    });
  });
}
