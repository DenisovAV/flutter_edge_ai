// Opt-in Qualcomm NPU stack for Linux arm64, for hook/build.dart.
//
// Same licence as on Android (Qualcomm's AI Stack License: redistribution only
// inside an application), so the same rule: this package never ships the QNN
// runtime; an app that sets `qualcomm_npu: true` gets it at build time. Linux
// has no Maven artifact, so the source is Qualcomm's public QAIRT SDK zip —
// 2.6 GB, of which the fourteen libraries a Linux app needs are ~30 MB
// compressed. The zip is read with HTTP range requests (its central directory,
// then those entries), never downloaded whole, and every library is checked
// against a SHA-256 pinned here.
//
// Everything here works on bytes, files and an injected reader, with no hook
// types, so it can be unit-tested without running a build.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter_edge_ai_litertlm/src/hook/download.dart';
import 'package:flutter_edge_ai_litertlm/src/hook/qnn_runtime.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';

/// The QAIRT SDK build the Linux libraries come from.
///
/// The same release as [qnnRuntimeVersion] on Android: the dispatch is built
/// against LiteRT's QAIRT pin (`third_party/qairt/workspace.bzl`), and
/// `build_qualcomm_dispatch.sh` refuses any other.
const qairtBuild = '2.50.0.260828';

/// Qualcomm's public download of [qairtBuild] (no login). Redirects once to
/// an API gateway that serves byte ranges.
final qairtZipUrl = Uri.parse(
  'https://softwarecenter.qualcomm.com/api/download/software/sdks/'
  'Qualcomm_AI_Runtime_Community/All/$qairtBuild/v$qairtBuild.zip',
);

/// Size of `v2.50.0.260828.zip` (sha256 a346ea0e2c8631b4…). A range response
/// for any other total is a different file, and is refused.
const qairtZipLength = 2601473189;

/// SHA-256 of each library as it sits in the zip, measured from the zip and
/// matching the libraries that ran Gemma 4 on the NPU of a QCS8275 board.
const qairtLinuxSha256 = {
  'libQnnHtp.so':
      '823f764d434869919c7e01825ba76da7db828225525b0d27a4c21f4b2841e25b',
  'libQnnSystem.so':
      '65c1faa1c2175128fd3c3c8a8edb276e93520666afd9696977e947e6d7a3d1d2',
  'libQnnHtpV68Stub.so':
      '8b37e04841fe2299c5325c2dd6d3ff54f73b68fff6151971742852de545e21b3',
  'libQnnHtpV68Skel.so':
      'e97388c45019995caa75c3c5c963e1dcce50081045f0eb4486e6365cb2ad83d6',
  'libQnnHtpV69Stub.so':
      '07e8b59dbe3318e600c2843a726a32510d80884263a5b0620b9ca82f7aecf3e0',
  'libQnnHtpV69Skel.so':
      '93c395d8fe86021708bb8ee8ed6926416794f6167e7a236e7d75d490ceb99e55',
  'libQnnHtpV73Stub.so':
      '84228f305bcac780abbc79dc5adff878bd0393b9eec3c1a7b0fbca5535319a69',
  'libQnnHtpV73Skel.so':
      'e3070ed8ec0fc24ea6e44ef54c599d43bcb1d95dd5aa377c0cd55d74f49fb2dd',
  'libQnnHtpV75Stub.so':
      'c9ca7044e946248ce8bbac85c54f720e9d732793fada9160ef82d037629e7046',
  'libQnnHtpV75Skel.so':
      '2f6cfe5aae553d8ec88b6741bf8598a557375eacfc58056c2667fc43fda64f6a',
  'libQnnHtpV79Stub.so':
      '41af4982799c61572b471256937799742f6bc948bbdf0015b724b1bb3c9f833e',
  'libQnnHtpV79Skel.so':
      '238675526b2932efe83a66784937e310ce238e76577e16e9c4358e81711e5333',
  'libQnnHtpV81Stub.so':
      '99faa17bd92b902561603916bf5df752d447cd4a858bf30f8c18bfd136f45ff3',
  'libQnnHtpV81Skel.so':
      '9b7266e38aea818a1caeba5cbfebd9a8cbdba8f25dd82126d9b44ebf4fec4fa0',
};

/// Qualcomm's licence and notices, kept beside the libraries in the cache.
const qairtNoticeFiles = ['LICENSE.pdf', 'QNN_NOTICE.txt'];

/// Bumped whenever what this file writes into the cache changes for the same
/// [qairtBuild].
const qairtCacheFormat = 1;

/// File names of the libraries a complete Linux cache entry holds.
List<String> get qairtLinuxFileNames => [
  for (final n in qairtLinuxLibs) androidLibFileName(n),
];

/// Directory name of the Linux cache entry.
String qairtCacheEntryName() => 'qairt-$qairtBuild-p$qairtCacheFormat';

/// Path of [fileName] inside the zip: arm64 host libraries from the
/// OpenEmbedded set (the Ubuntu set stops at V68), Skels from the Hexagon
/// version's unsigned directory.
String qairtEntryPath(String fileName) {
  final root = 'qairt/$qairtBuild';
  final skel = RegExp(r'^libQnnHtpV(\d+)Skel\.so$').firstMatch(fileName);
  if (skel != null) {
    return '$root/lib/hexagon-v${skel.group(1)}/unsigned/$fileName';
  }
  if (qairtNoticeFiles.contains(fileName)) return '$root/$fileName';
  return '$root/lib/aarch64-oe-linux-gcc11.2/$fileName';
}

/// The Linux libraries and notices from [entries] (zip path → bytes), each
/// library checked against [qairtLinuxSha256].
({Map<String, Uint8List> libraries, Map<String, Uint8List> notices})
qairtFilesFrom(
  Map<String, Uint8List> entries, {
  Map<String, String> pins = qairtLinuxSha256,
}) {
  final libraries = <String, Uint8List>{};
  for (final f in qairtLinuxFileNames) {
    final bytes = entries[qairtEntryPath(f)];
    if (bytes == null) throw FormatException('$f is missing from QAIRT');
    final actual = sha256.convert(bytes).toString();
    if (actual != pins[f]) {
      throw StateError(
        '$f from QAIRT $qairtBuild has sha256 $actual, expected '
        '${pins[f]} — not the release this package pins',
      );
    }
    libraries[f] = bytes;
  }
  return (
    libraries: libraries,
    notices: {
      for (final f in qairtNoticeFiles) f: ?entries[qairtEntryPath(f)],
    },
  );
}

/// Every zip entry the Linux stack takes.
Set<String> get qairtEntryPaths => {
  for (final f in [...qairtLinuxFileNames, ...qairtNoticeFiles])
    qairtEntryPath(f),
};

/// Reads the Linux stack out of a local copy of the QAIRT zip.
({Map<String, Uint8List> libraries, Map<String, Uint8List> notices})
qairtFilesFromZip(File zip) {
  final length = zip.lengthSync();
  if (length != qairtZipLength) {
    throw StateError(
      '${zip.path} is $length bytes; v$qairtBuild.zip is $qairtZipLength',
    );
  }
  return qairtFilesFrom(extractZipEntriesFromFile(zip, qairtEntryPaths));
}

/// Reads the Linux stack out of the QAIRT zip through [readAt] — in a build,
/// [httpRangeReader] over [qairtZipUrl].
Future<({Map<String, Uint8List> libraries, Map<String, Uint8List> notices})>
fetchQairtFiles(ReadAtAsync readAt) async => qairtFilesFrom(
  await extractZipEntriesAsync(readAt, qairtZipLength, qairtEntryPaths),
);

/// A [ReadAtAsync] over HTTP range requests to [url], for a file of
/// [expectedLength] bytes.
///
/// Every answer must be `206` with a `Content-Range` naming exactly the
/// requested bytes of a file of [expectedLength] — a server that ignores the
/// range would otherwise start sending 2.6 GB, and one serving a different
/// file must not get as far as a checksum. Redirects are followed here rather
/// than by [HttpClient], once, so every later range goes straight to where the
/// file is. Transient failures (network, 429, 5xx) are retried with backoff.
ReadAtAsync httpRangeReader(
  Uri url, {
  required int expectedLength,
  int attempts = 3,
  int maxRedirects = 5,
  Duration connectTimeout = const Duration(seconds: 30),
  Duration idleTimeout = const Duration(seconds: 60),
  Duration backoff = const Duration(seconds: 2),
}) {
  Uri? resolved;

  Future<Uint8List> once(HttpClient client, int offset, int length) async {
    var target = resolved ?? url;
    for (var hop = 0; ; hop++) {
      final request = await client.getUrl(target).timeout(connectTimeout);
      request
        ..followRedirects = false
        ..headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$offset-${offset + length - 1}',
        );
      final response = await request.close().timeout(connectTimeout);
      final status = response.statusCode;
      if (response.isRedirect) {
        await response.drain<void>().catchError((_) {});
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || hop >= maxRedirects) {
          throw _Fatal(HttpException('HTTP $status without a usable redirect'));
        }
        target = target.resolve(location);
        continue;
      }
      if (status != 206) {
        // Never read the body: a 200 here is the whole archive. The client is
        // closed with force below, which drops the connection.
        final transient = status == 429 || status >= 500;
        final error = HttpException(
          status == 200
              ? 'HTTP 200 for a range request — the server does not serve '
                    'byte ranges'
              : 'HTTP $status',
        );
        if (!transient) throw _Fatal(error);
        throw error;
      }
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      final want = 'bytes $offset-${offset + length - 1}/$expectedLength';
      if (range != want) {
        await response.drain<void>().catchError((_) {});
        throw _Fatal(
          StateError(
            'Content-Range "$range", expected "$want" — a different file',
          ),
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(
        idleTimeout,
        onTimeout: (sink) => sink.addError(
          TimeoutException('no data for ${idleTimeout.inSeconds}s'),
        ),
      )) {
        builder.add(chunk);
        if (builder.length > length) break;
      }
      if (builder.length != length) {
        throw HttpException('got ${builder.length} of $length bytes');
      }
      resolved = target;
      return builder.takeBytes();
    }
  }

  return (offset, length) async {
    if (offset < 0 || length <= 0 || offset + length > expectedLength) {
      throw RangeError('bytes $offset+$length of $expectedLength');
    }
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final client = HttpClient()..connectionTimeout = connectTimeout;
      try {
        return await once(client, offset, length);
      } on _Fatal catch (f) {
        throw f.error;
      } on Object catch (e) {
        lastError = e;
        if (attempt < attempts) await Future<void>.delayed(backoff * attempt);
      } finally {
        client.close(force: true);
      }
    }
    throw StateError(
      'could not read bytes $offset+$length of ${redactUserInfo(url)} after '
      '$attempts attempts: ${redactUserInfoIn('$lastError', url)}',
    );
  };
}

class _Fatal {
  _Fatal(this.error);
  final Object error;
}
