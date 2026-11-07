import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:showcase_functions/src/source_check.dart';
import 'package:showcase_functions/src/stores.dart';
import 'package:showcase_functions/src/submission.dart';
import 'package:test/test.dart';

const _app = '''
name: shop
dependencies:
  flutter:
    sdk: flutter
  flutter_gemma: ^0.13.0
  flutter_edge_ai_litertlm:
    path: ../litertlm
dev_dependencies:
  flutter_edge_ai_diagnostics: any
''';

const _other = '''
name: other
dependencies:
  http: ^1.2.0
''';

/// A fake GitHub: [files] by raw path (`owner/repo/ref/path`), and the tree
/// the trees API returns, or [treeStatus] instead.
SourceCheck _check(Map<String, String> files, {List<String> tree = const [], int treeStatus = 200}) {
  final requests = <String>[];
  addTearDown(() => printOnFailure('requests: $requests'));
  return SourceCheck(
    MockClient((request) async {
      requests.add('${request.url.host}${request.url.path}');
      if (request.url.host == 'raw.githubusercontent.com') {
        final body = files[request.url.path.substring(1)];
        return body == null ? http.Response('404: Not Found', 404) : http.Response(body, 200);
      }
      if (treeStatus != 200) return http.Response('{}', treeStatus);
      return http.Response(
        jsonEncode({
          'tree': [
            for (final path in tree) {'type': 'blob', 'path': path},
          ],
        }),
        200,
      );
    }),
  );
}

Matcher _refused(String message) =>
    throwsA(isA<SubmissionException>().having((e) => e.message, 'message', contains(message)));

void main() {
  group('parseGitHubUrl', () {
    test('a repository', () {
      expect(parseGitHubUrl('https://github.com/yegobox/flipper'), (
        owner: 'yegobox',
        repo: 'flipper',
        ref: null,
        path: null,
      ));
      expect(parseGitHubUrl('https://github.com/yegobox/flipper.git/').repo, 'flipper');
    });

    test('a folder on a branch', () {
      expect(parseGitHubUrl('https://github.com/owner/mono/tree/main/apps/shop'), (
        owner: 'owner',
        repo: 'mono',
        ref: 'main',
        path: 'apps/shop',
      ));
    });

    test('refuses other hosts and pages', () {
      for (final url in [
        'http://github.com/owner/repo',
        'https://gitlab.com/owner/repo',
        'https://github.com/owner',
        'https://github.com/owner/repo/blob/main/pubspec.yaml',
        'https://github.com/owner/repo/tree',
        'https://github.com/-owner/repo',
      ]) {
        expect(() => parseGitHubUrl(url), _refused('GitHub link'), reason: url);
      }
    });
  });

  test('showcaseDependencies reads only dependencies, satellites included', () {
    expect(showcaseDependencies(_app), ['flutter_edge_ai_litertlm', 'flutter_gemma']);
    expect(showcaseDependencies(_other), isEmpty);
    expect(showcaseDependencies('not: [yaml'), isEmpty);
  });

  group('SourceCheck', () {
    const repo = (owner: 'o', repo: 'r', ref: null, path: null);

    test('the root pubspec, without the trees API', () async {
      final found = await _check({'o/r/HEAD/pubspec.yaml': _app}, treeStatus: 500).find(repo);
      expect(found.pubspecPath, 'pubspec.yaml');
      expect(found.packages, ['flutter_edge_ai_litertlm', 'flutter_gemma']);
    });

    test('a pubspec deeper in the tree, nearest first, generated folders skipped', () async {
      final found = await _check(
        {
          'o/r/HEAD/pubspec.yaml': _other,
          'o/r/HEAD/apps/shop/pubspec.yaml': _app,
          'o/r/HEAD/apps/shop/build/x/pubspec.yaml': _app,
        },
        tree: ['apps/shop/build/x/pubspec.yaml', 'apps/shop/pubspec.yaml', 'pubspec.yaml'],
      ).find(repo);
      expect(found.pubspecPath, 'apps/shop/pubspec.yaml');
    });

    test('a dependency in the 25th of 30 pubspecs', () async {
      final tree = [for (var i = 0; i < 30; i++) 'packages/p$i/pubspec.yaml'];
      final found = await _check({
        for (final path in tree) 'o/r/HEAD/$path': _other,
        'o/r/HEAD/packages/p24/pubspec.yaml': _app,
      }, tree: tree).find(repo);
      expect(found.pubspecPath, 'packages/p24/pubspec.yaml');
    });

    test('the folder the link names', () async {
      final found = await _check({
        'o/r/main/apps/shop/pubspec.yaml': _app,
      }).find((owner: 'o', repo: 'r', ref: 'main', path: 'apps/shop'));
      expect(found.pubspecPath, 'apps/shop/pubspec.yaml');
    });

    test('refuses a repository whose pubspecs do not depend on the packages', () async {
      await expectLater(
        _check({'o/r/HEAD/pubspec.yaml': _other}, tree: ['pubspec.yaml', 'tool/pubspec.yaml']).find(repo),
        _refused('No pubspec.yaml in o/r depends on'),
      );
    });

    test('refuses a repository that is not public', () async {
      await expectLater(_check({}, treeStatus: 404).find(repo), _refused('GitHub has no public repository o/r'));
    });

    test('a rate-limited API is GitHub being unavailable, not a refusal', () async {
      await expectLater(
        _check({'o/r/HEAD/pubspec.yaml': _other}, treeStatus: 403).find(repo),
        throwsA(isA<StoreUnavailableException>().having((e) => e.service, 'service', 'GitHub')),
      );
    });
  });
}
