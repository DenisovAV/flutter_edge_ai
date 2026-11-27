import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:model_registry/check.dart';
import 'package:model_registry/pub_dev.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _hook(Map<String, String> archives) => [
  '  checksums: {',
  for (final MapEntry(key: host, value: sha) in archives.entries)
    "    '${hostArchives[host]}':\n        '$sha',",
  '  },',
].join('\n');

final _archives = {'macos_arm64': 'a' * 64, 'linux_x64': 'b' * 64};

/// A ustar .tar.gz of [files].
List<int> _tarGz(Map<String, String> files) {
  final out = BytesBuilder();
  for (final MapEntry(key: name, value: text) in files.entries) {
    final data = utf8.encode(text);
    final header = List<int>.filled(512, 0);
    void put(int at, String s) =>
        header.setRange(at, at + s.length, ascii.encode(s));
    put(0, name);
    put(100, '0000644');
    put(124, data.length.toRadixString(8).padLeft(11, '0'));
    put(136, '00000000000');
    header[156] = 0x30;
    put(257, 'ustar');
    header.setRange(148, 156, List.filled(8, 0x20));
    final sum = header.fold<int>(0, (a, b) => a + b);
    put(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
    out
      ..add(header)
      ..add(data)
      ..add(List.filled((512 - data.length % 512) % 512, 0));
  }
  out.add(List.filled(1024, 0));
  return gzip.encode(out.takeBytes());
}

PubDevPin _pin({String adapter = '1.2.3', Map<String, String>? archives}) =>
    PubDevPin(
      packages: {adapterPackage: adapter, 'flutter_edge_ai_speech': '0.1.0'},
      litertlmDart: '0.9.0+1',
      nativeRelease: 'native-v0.9.0-a',
      archives: archives ?? _archives,
    );

void main() {
  group('the hook', () {
    test('archives and the tag are read from the sources', () {
      expect(hookArchives(_hook(_archives)), _archives);
      expect(
        nativeReleaseTag("const liteRtLmNativeVersion = '0.19.1-c';"),
        'native-v0.19.1-c',
      );
    });

    test('the web is judged by the adapter version', () {
      expect(_pin().nativeFor('web'), '$adapterPackage@1.2.3');
      expect(_pin().nativeFor('macos_arm64'), 'a' * 64);
      expect(_pin().nativeFor('ios_arm64'), isNull);
    });
  });

  group('the file', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('pub_dev_test'));
    tearDown(() => root.deleteSync(recursive: true));
    void write(String path, String content) => File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    test('what toYaml writes, readPin reads', () {
      write('model_registry/$pinFile', _pin().toYaml());
      final problems = <Problem>[];
      final read = readPin(
        Directory(p.join(root.path, 'model_registry')),
        problems,
      );
      expect(problems, isEmpty);
      expect(read!.toYaml(), _pin().toYaml());
    });

    test('a malformed archive and an unknown key', () {
      write(
        'model_registry/$pinFile',
        '${_pin().toYaml()}extra: 1\n'.replaceFirst('a' * 64, 'xyz'),
      );
      final problems = <Problem>[];
      readPin(Directory(p.join(root.path, 'model_registry')), problems);
      expect(problems.map((x) => '$x'), [
        contains('extra: unknown key'),
        contains('archives.macos_arm64: malformed "xyz"'),
      ]);
    });

    void workspace({String dep = '0.9.0+2', String lt = '0.9.0+2'}) {
      write(
        'packages/$adapterPackage/pubspec.yaml',
        'name: $adapterPackage\nversion: 1.3.0\n'
            'dependencies:\n  litertlm_dart: $dep\n',
      );
      write(
        'packages/flutter_edge_ai_speech/pubspec.yaml',
        'name: flutter_edge_ai_speech\nversion: 0.2.0\n',
      );
      write('packages/litertlm_dart/pubspec.yaml', 'name: x\nversion: $lt\n');
      write(
        'packages/litertlm_dart/lib/src/runtime/native_release.dart',
        "const liteRtLmNativeVersion = '0.9.0-b';\n",
      );
      write(
        'packages/litertlm_dart/hook/build.dart',
        _hook({'macos_arm64': 'c' * 64, 'linux_x64': 'd' * 64}),
      );
    }

    test('pin moves the adapter, its litertlm_dart and the native build', () {
      workspace();
      final moved = movePin(_pin(), root.path, adapterPackage);
      expect(moved.packages, {
        adapterPackage: '1.3.0',
        'flutter_edge_ai_speech': '0.1.0',
      });
      expect(moved.litertlmDart, '0.9.0+2');
      expect(moved.nativeRelease, 'native-v0.9.0-b');
      expect(moved.archives, {'macos_arm64': 'c' * 64, 'linux_x64': 'd' * 64});
    });

    test('pin moves speech alone', () {
      workspace();
      final moved = movePin(_pin(), root.path, 'flutter_edge_ai_speech');
      expect(moved.packages['flutter_edge_ai_speech'], '0.2.0');
      expect(moved.packages[adapterPackage], '1.2.3');
      expect(moved.archives, _archives);
    });

    test('pin refuses a range or a litertlm_dart the workspace lacks', () {
      workspace(dep: '^0.9.0');
      expect(
        () => movePin(_pin(), root.path, adapterPackage),
        throwsA(isA<StateError>()),
      );
      workspace(lt: '0.9.0+3');
      expect(
        () => movePin(_pin(), root.path, adapterPackage),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('pub-check', () {
    late HttpServer server;
    late Map<String, Object?> adapterLatest;
    late List<int> archive;
    setUp(() async {
      adapterLatest = {
        'version': '1.2.3',
        'pubspec': {
          'dependencies': {'litertlm_dart': '0.9.0+1'},
        },
      };
      archive = _tarGz({
        'hook/build.dart': _hook(_archives),
        'lib/src/runtime/native_release.dart':
            "const liteRtLmNativeVersion = '0.9.0-a';\n",
      });
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        final path = Uri.decodeComponent(req.uri.path);
        void json(Object o) => req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(o))
          ..close();
        if (path == '/api/packages/$adapterPackage') {
          json({'latest': adapterLatest});
        } else if (path == '/api/packages/flutter_edge_ai_speech') {
          json({
            'latest': {'version': '0.1.0', 'pubspec': <String, Object?>{}},
          });
        } else if (path == '/api/packages/litertlm_dart/versions/0.9.0+1') {
          json({
            'archive_url':
                'http://127.0.0.1:${server.port}/litertlm_dart.tar.gz',
          });
        } else if (path == '/litertlm_dart.tar.gz') {
          req.response
            ..add(archive)
            ..close();
        } else {
          req.response
            ..statusCode = 404
            ..close();
        }
      });
    });
    tearDown(() => server.close(force: true));
    Uri base() => Uri.parse('http://127.0.0.1:${server.port}');

    test('a pin that matches pub.dev', () async {
      expect(await pubCheck(_pin(), base: base()), isEmpty);
    });

    test('a newer adapter on pub.dev, on another litertlm_dart', () async {
      adapterLatest = {
        'version': '1.3.0',
        'pubspec': {
          'dependencies': {'litertlm_dart': '0.9.0+2'},
        },
      };
      expect(await pubCheck(_pin(), base: base()), [
        contains('pinned 1.2.3, pub.dev has 1.3.0'),
        contains('pins litertlm_dart 0.9.0+2'),
      ]);
    });

    test('archives that differ from the published hook', () async {
      expect(
        await pubCheck(
          _pin(archives: {..._archives, 'linux_x64': 'e' * 64}),
          base: base(),
        ),
        [contains('archives.linux_x64: pub.dev ${'b' * 64}')],
      );
    });
  });
}
