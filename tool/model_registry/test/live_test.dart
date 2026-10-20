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

  setUp(() async {
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

  tearDown(() => server.close(force: true));

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
        'org/repo/gated.bin': (LiveStatus.noAccess, 'GatedRepo'),
        'org/repo/gone.bin': (LiveStatus.missing, 'HTTP 404'),
        'old/repo/model.bin': (LiveStatus.ok, 'linked'),
      },
    );
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
