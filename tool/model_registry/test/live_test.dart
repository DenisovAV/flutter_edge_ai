import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:model_registry/live.dart';
import 'package:test/test.dart';

const _rev = '0123456789abcdef0123456789abcdef01234567';

LiveArtifact _artifact(String path, String sha, int size) =>
    (repo: 'org/repo', revision: _rev, path: path, sha256: sha, size: size);

void main() {
  late HttpServer server;
  late Uri base;
  final small = utf8.encode('{"tokenizer": true}');
  final smallSha = '${sha256.convert(small)}';
  final lfsSha = 'a' * 64;

  late HttpServer elsewhere;
  final authorizations = <String, String?>{};

  setUp(() async {
    authorizations.clear();
    elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    elsewhere.listen((request) async {
      if (request.uri.path == '/plain/tok.json') {
        // A plain file on another host: answered as itself, then fetched.
        authorizations['elsewhere ${request.method}'] = request.headers.value(
          'authorization',
        );
        if (request.method == 'GET') request.response.add(small);
        await request.response.close();
        return;
      }
      authorizations['elsewhere'] = request.headers.value('authorization');
      request.response
        ..statusCode = 302
        ..headers.set('location', '/cdn/model')
        ..headers.set('x-linked-etag', '"$lfsSha"')
        ..headers.set('x-linked-size', '1000');
      await request.response.close();
    });
    // Hugging Face as the check sees it: LFS files redirect with the linked
    // sha256 and size; a plain git file redirects with its git oid and is
    // fetched; a gated repo answers 401; a renamed repo redirects to its
    // new name.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      final r = request.response;
      final path = request.uri.path;
      if (path == '/org/repo/resolve/$_rev/model.bin') {
        r
          ..statusCode = 302
          ..headers.set('location', '/cdn/model')
          ..headers.set('x-linked-etag', '"$lfsSha"')
          ..headers.set('x-linked-size', '1000');
      } else if (path == '/org/repo/resolve/$_rev/tok.json') {
        if (request.method == 'HEAD') {
          r
            ..statusCode = 307
            ..headers.set('location', '/cdn/tok')
            ..headers.set('x-linked-etag', '"${'1' * 40}"');
        } else {
          r
            ..statusCode = 307
            ..headers.set('location', '/cdn/tok');
        }
      } else if (path == '/cdn/tok') {
        r.add(small);
      } else if (path == '/org/repo/resolve/$_rev/gated.bin') {
        r
          ..statusCode = 401
          ..headers.set('x-error-code', 'GatedRepo');
      } else if (path == '/deleted/repo/resolve/$_rev/model.bin') {
        r
          ..statusCode = 401
          ..headers.set('x-error-code', 'RepoNotFound');
      } else if (path == '/away/repo/resolve/$_rev/tok.json') {
        r
          ..statusCode = 307
          ..headers.set(
            'location',
            'http://localhost:${elsewhere.port}/plain/tok.json',
          );
      } else if (path == '/away/repo/resolve/$_rev/model.bin') {
        authorizations['away'] = request.headers.value('authorization');
        r
          ..statusCode = 307
          ..headers.set(
            'location',
            'http://localhost:${elsewhere.port}/org/repo/resolve/$_rev/model.bin',
          );
      } else if (path == '/old/repo/resolve/$_rev/model.bin') {
        r
          ..statusCode = 307
          ..headers.set('location', '/org/repo/resolve/$_rev/model.bin');
      } else {
        r.statusCode = 404;
      }
      await r.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await elsewhere.close(force: true);
  });

  Future<Map<String, (LiveStatus, String)>> run(List<LiveArtifact> a) async => {
    for (final r in await checkLive(a, base: base, concurrency: 2))
      '${r.artifact.repo}/${r.artifact.path}': (r.status, r.note),
  };

  test('a linked file is checked by its etag and size', () async {
    expect(await run([_artifact('model.bin', lfsSha, 1000)]), {
      'org/repo/model.bin': (LiveStatus.ok, 'linked'),
    });
    expect(
      (await run([
        _artifact('model.bin', 'b' * 64, 1000),
      ]))['org/repo/model.bin']!.$1,
      LiveStatus.mismatch,
    );
    expect(
      (await run([
        _artifact('model.bin', lfsSha, 999),
      ]))['org/repo/model.bin']!.$2,
      'size is 1000',
    );
  });

  test('a plain git file is fetched and hashed', () async {
    expect(await run([_artifact('tok.json', smallSha, small.length)]), {
      'org/repo/tok.json': (LiveStatus.ok, 'fetched'),
    });
    expect(
      (await run([
        _artifact('tok.json', smallSha, small.length + 1),
      ]))['org/repo/tok.json']!.$1,
      LiveStatus.mismatch,
    );
  });

  test('gated is no access, gone is missing, a rename is followed', () async {
    final renamed = (
      repo: 'old/repo',
      revision: _rev,
      path: 'model.bin',
      sha256: lfsSha,
      size: 1000,
    );
    expect(
      await run([
        _artifact('gated.bin', lfsSha, 1),
        _artifact('gone.bin', lfsSha, 1),
        renamed,
      ]),
      {
        'org/repo/gated.bin': (LiveStatus.noAccess, 'GatedRepo; no HF_TOKEN'),
        'org/repo/gone.bin': (LiveStatus.missing, 'HTTP 404'),
        'old/repo/model.bin': (LiveStatus.ok, 'linked'),
      },
    );
  });

  test('the token goes to the Hugging Face host only', () async {
    final away = (
      repo: 'away/repo',
      revision: _rev,
      path: 'model.bin',
      sha256: lfsSha,
      size: 1000,
    );
    final plain = (
      repo: 'away/repo',
      revision: _rev,
      path: 'tok.json',
      sha256: '${sha256.convert(small)}',
      size: small.length,
    );
    await checkLive([away, plain], base: base, token: 'hf_secret');
    expect(authorizations, contains('elsewhere GET'));
    expect(authorizations['elsewhere GET'], isNull);
    expect(authorizations['elsewhere HEAD'], isNull);
    expect(authorizations['away'], 'Bearer hf_secret');
    expect(authorizations, contains('elsewhere'));
    expect(authorizations['elsewhere'], isNull);
  });

  test('a deleted repository is missing, not no access', () async {
    final deleted = (
      repo: 'deleted/repo',
      revision: _rev,
      path: 'model.bin',
      sha256: lfsSha,
      size: 1000,
    );
    expect(await run([deleted]), {
      'deleted/repo/model.bin': (LiveStatus.missing, 'RepoNotFound (HTTP 401)'),
    });
  });

  test('a file nobody could check fails the run', () async {
    final results = await checkLive([
      _artifact('model.bin', lfsSha, 1000),
    ], base: base);
    expect(liveFailed(results), isFalse);
    final gated = await checkLive([
      _artifact('model.bin', lfsSha, 1000),
      _artifact('gated.bin', lfsSha, 1),
    ], base: base);
    expect(liveFailed(gated), isTrue, reason: 'no HF_TOKEN: unchecked');
    final withToken = await checkLive(
      [_artifact('gated.bin', lfsSha, 1)],
      base: base,
      token: 'expired',
    );
    expect(withToken.single.note, 'GatedRepo; the token has no access');
    expect(liveFailed(withToken), isTrue);
  });

  test('every pinned file once, tokenizers and bundles included', () {
    final file = {
      'repo': 'r',
      'revision': _rev,
      'path': 'a',
      'sha256': lfsSha,
      'size': 1,
    };
    final artifacts = liveArtifacts([
      {'file': file},
      {
        'file': file,
        'tokenizer': {...file, 'path': 't'},
      },
      {
        'files': [
          {...file, 'path': 'b'},
          {...file, 'path': 'c'},
        ],
      },
    ]);
    expect([for (final a in artifacts) a.path], ['a', 't', 'b', 'c']);
  });

  test('the summary lists what is not ok, failures first', () {
    final s = liveSummary([
      (artifact: _artifact('x', lfsSha, 1), status: LiveStatus.ok, note: ''),
      (
        artifact: _artifact('g', lfsSha, 1),
        status: LiveStatus.noAccess,
        note: 'GatedRepo',
      ),
      (
        artifact: _artifact('m', lfsSha, 1),
        status: LiveStatus.missing,
        note: 'HTTP 404',
      ),
    ]);
    expect(s, contains('ok: 1 · noAccess: 1 · missing: 1'));
    expect(s.indexOf('| missing |'), lessThan(s.indexOf('| noAccess |')));
    expect(s, isNot(contains('| ok |')));
  });
}
