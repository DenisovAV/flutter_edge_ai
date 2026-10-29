// Live check: every artifact the registry pins is still served by Hugging
// Face at its commit, with the registry's sha256 and size. The weekly
// workflow runs it (.github/workflows/model-registry-live.yml); it is the one
// part of the tool that reaches the network, so pull requests never run it.
//
// Hugging Face answers a `resolve/<commit>/<path>` HEAD with a redirect. For a
// file in LFS or Xet storage the redirect carries `X-Linked-Etag` (the
// sha256) and `X-Linked-Size`; for a plain git file it carries the git object
// id, so the file is fetched and hashed. A gated repository answers 401
// without a token that has access: `noAccess`, which fails the run like any
// file that was not checked (a missing or expired HF_TOKEN must not turn the
// weekly run green over files nobody looked at). Hugging Face also answers
// 401 for a repository, revision or file that does not exist; its
// `X-Error-Code` names that, and it is `missing`.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// One pinned file.
typedef LiveArtifact = ({
  String repo,
  String revision,
  String path,
  String sha256,
  int size,
});

/// What Hugging Face said about one artifact.
enum LiveStatus { ok, noAccess, missing, mismatch, error }

typedef LiveResult = ({LiveArtifact artifact, LiveStatus status, String note});

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

/// The `X-Error-Code`s with which Hugging Face says a file is not there,
/// whatever the HTTP status.
const _goneCodes = {'RepoNotFound', 'RevisionNotFound', 'EntryNotFound'};

/// The statuses that fail the run: everything but [LiveStatus.ok].
bool liveFailed(Iterable<LiveResult> results) =>
    results.any((r) => r.status != LiveStatus.ok);

/// Checks [artifacts] against [base] (https://huggingface.co in production),
/// [concurrency] at a time.
Future<List<LiveResult>> checkLive(
  List<LiveArtifact> artifacts, {
  Uri? base,
  String? token,
  int concurrency = 8,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final root = base ?? Uri.parse('https://huggingface.co');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final results = List<LiveResult?>.filled(artifacts.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < artifacts.length) {
      final i = next++;
      final a = artifacts[i];
      try {
        results[i] = await _check(client, root, a, token).timeout(timeout);
      } catch (e) {
        results[i] = (artifact: a, status: LiveStatus.error, note: '$e');
      }
    }
  }

  await Future.wait([for (var w = 0; w < concurrency; w++) worker()]);
  client.close(force: true);
  return results.cast<LiveResult>();
}

Future<LiveResult> _check(
  HttpClient client,
  Uri root,
  LiveArtifact a,
  String? token,
) async {
  final segments = a.path.split('/').map(Uri.encodeComponent).join('/');
  var url = root.resolve('/${a.repo}/resolve/${a.revision}/$segments');
  LiveResult result(LiveStatus s, String note) =>
      (artifact: a, status: s, note: note);

  // A renamed repository answers with a redirect to the new name (no linked
  // etag); follow a few of those, and stop at the one that names the file.
  for (var hop = 0; hop < 4; hop++) {
    final request = await client.headUrl(url);
    request.followRedirects = false;
    // The token is for Hugging Face only, not a host a redirect names.
    if (token != null &&
        url.scheme == root.scheme &&
        url.host == root.host &&
        url.port == root.port) {
      request.headers.set('authorization', 'Bearer $token');
    }
    final response = await request.close();
    await response.drain<void>();
    final status = response.statusCode;
    final code = response.headers.value('x-error-code');
    if (code != null && _goneCodes.contains(code)) {
      return result(LiveStatus.missing, '$code (HTTP $status)');
    }
    if (status == 401 || status == 403) {
      return result(
        LiveStatus.noAccess,
        '${code ?? 'HTTP $status'}; '
        '${token == null ? 'no HF_TOKEN' : 'the token has no access'}',
      );
    }
    if (status == 404) return result(LiveStatus.missing, 'HTTP 404');
    final etag = response.headers
        .value('x-linked-etag')
        ?.replaceAll('"', '')
        .toLowerCase();
    final linkedSize = int.tryParse(
      response.headers.value('x-linked-size') ?? '',
    );
    if (status >= 300 && status < 400 && etag == null) {
      final location = response.headers.value('location');
      if (location == null) return result(LiveStatus.error, 'HTTP $status');
      url = url.resolve(location);
      continue;
    }
    if (etag != null && _sha256.hasMatch(etag)) {
      if (etag != a.sha256) {
        return result(LiveStatus.mismatch, 'sha256 is $etag');
      }
      if (linkedSize != null && linkedSize != a.size) {
        return result(LiveStatus.mismatch, 'size is $linkedSize');
      }
      return result(LiveStatus.ok, 'linked');
    }
    if (status >= 400) return result(LiveStatus.error, 'HTTP $status');
    // A plain git file: fetch it and hash it.
    final get = await client.getUrl(url);
    if (token != null) get.headers.set('authorization', 'Bearer $token');
    final body = await get.close();
    if (body.statusCode != 200) {
      await body.drain<void>();
      return result(LiveStatus.error, 'GET HTTP ${body.statusCode}');
    }
    var length = 0;
    final digest = await sha256
        .bind(
          body.map((chunk) {
            length += chunk.length;
            return chunk;
          }),
        )
        .first;
    if ('$digest' != a.sha256) {
      return result(LiveStatus.mismatch, 'sha256 is $digest');
    }
    if (length != a.size) return result(LiveStatus.mismatch, 'size is $length');
    return result(LiveStatus.ok, 'fetched');
  }
  return result(LiveStatus.error, 'too many redirects');
}

/// Every pinned file of [entries]' variants, once each.
List<LiveArtifact> liveArtifacts(List<Map<String, Object?>> variants) {
  final seen = <String>{};
  final out = <LiveArtifact>[];
  void add(Object? a) {
    if (a case {
      'repo': final String repo,
      'revision': final String revision,
      'path': final String path,
      'sha256': final String sha,
      'size': final int size,
    }) {
      if (seen.add('$repo@$revision/$path')) {
        out.add((
          repo: repo,
          revision: revision,
          path: path,
          sha256: sha,
          size: size,
        ));
      }
    }
  }

  for (final v in variants) {
    add(v['file']);
    add(v['tokenizer']);
    for (final f in (v['files'] as List? ?? const [])) {
      add(f);
    }
  }
  return out;
}

/// A Markdown summary of [results], failures first.
String liveSummary(List<LiveResult> results) {
  final out = StringBuffer('## Model registry: Hugging Face files\n\n');
  final counts = <LiveStatus, int>{};
  for (final r in results) {
    counts[r.status] = (counts[r.status] ?? 0) + 1;
  }
  out.writeln(
    [
      for (final s in LiveStatus.values)
        if (counts[s] case final n?) '${s.name}: $n',
    ].join(' · '),
  );
  final listed = [
    for (final r in results)
      if (r.status != LiveStatus.ok) r,
  ]..sort((a, b) => a.status.index.compareTo(b.status.index));
  if (listed.isNotEmpty) {
    out
      ..writeln()
      ..writeln('| Status | File | Note |')
      ..writeln('|---|---|---|');
    for (final r in listed.reversed) {
      final a = r.artifact;
      out.writeln(
        '| ${r.status.name} | ${a.repo}@${a.revision.substring(0, 8)}/'
        '${a.path} | ${r.note} |',
      );
    }
  }
  return out.toString();
}
