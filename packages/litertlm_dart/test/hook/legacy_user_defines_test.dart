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

  group('legacyUserDefinesRefusal', () {
    test('no define under the old key: no refusal', () {
      expect(legacyUserDefinesRefusal(const {}, '/ws/pubspec.yaml'), isNull);
    });

    test(
      'a define under the old key fails the build and names the new key',
      () {
        final message = legacyUserDefinesRefusal({
          'qualcomm_npu': true,
          'mediatek_npu': true,
        }, '/ws/pubspec.yaml');
        expect(
          message,
          allOf(
            contains('/ws/pubspec.yaml'),
            contains(
              'hooks.user_defines.flutter_edge_ai_litertlm.mediatek_npu',
            ),
            contains(
              'hooks.user_defines.flutter_edge_ai_litertlm.qualcomm_npu',
            ),
            contains('hooks.user_defines.litertlm_dart'),
            contains(
              'litertlm_dart: mediatek_npu, litertlm_dart: qualcomm_npu',
            ),
            contains('0.20.0'),
          ),
        );
      },
    );
  });

  group('legacyUserDefinesRefusal, macos_companions', () {
    test('alone under the old key: delete it, nothing to move', () {
      final message = legacyUserDefinesRefusal({
        'macos_companions': 'code_assets',
      }, '/ws/pubspec.yaml')!;
      expect(
        message,
        allOf(
          contains(
            'Delete hooks.user_defines.flutter_edge_ai_litertlm.'
            'macos_companions: it is obsolete',
          ),
          isNot(contains('Move')),
          isNot(contains('litertlm_dart: macos_companions')),
        ),
      );
    });

    test('beside others: those are moved, it is deleted', () {
      final message = legacyUserDefinesRefusal({
        'macos_companions': 'code_assets',
        'qualcomm_npu': true,
      }, '/ws/pubspec.yaml')!;
      expect(
        message,
        allOf(
          contains(
            'Move hooks.user_defines.flutter_edge_ai_litertlm.qualcomm_npu '
            'to hooks.user_defines.litertlm_dart (litertlm_dart: '
            'qualcomm_npu)',
          ),
          contains(
            'Delete hooks.user_defines.flutter_edge_ai_litertlm.'
            'macos_companions',
          ),
          isNot(contains('litertlm_dart: macos_companions')),
        ),
      );
    });
  });

  group('HookDefines', () {
    HookDefines defines({Map<String, Object?> current = const {}}) =>
        HookDefines(
          current: (key) => current[key],
          currentPath: (key) => switch (current[key]) {
            final String path => Uri.file('/app/$path'),
            _ => null,
          },
        );

    test('reads the current key', () {
      final d = defines(current: {'qualcomm_npu': false});
      expect(d['qualcomm_npu'], isFalse);
      expect(d.packageOf('qualcomm_npu'), 'litertlm_dart');
    });

    test('a key that is not set is null', () {
      expect(defines()['mediatek_npu'], isNull);
      expect(defines().path('qualcomm_npu_aar'), isNull);
    });

    test('a path resolves against the pubspec that set it', () {
      final d = defines(current: {'qualcomm_npu_aar': 'mine.aar'});
      expect(d.path('qualcomm_npu_aar'), Uri.file('/app/mine.aar'));
    });
  });
}
