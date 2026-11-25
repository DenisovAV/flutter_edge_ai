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

import 'package:litertlm_dart/src/hook/download.dart';
import 'package:litertlm_dart/src/hook/qnn_runtime.dart';
import 'package:litertlm_dart/src/runtime/npu_stacks.dart';

/// The QAIRT SDK build the Linux libraries come from.
///
/// The same release as [qnnRuntimeVersion] on Android: the dispatch is built
/// against it (a local SDK through `LITERT_QAIRT_SDK`, the slice of
/// `fetch_qairt_sdk_slim.py`), and `build_qualcomm_dispatch.sh` refuses any
/// other.
const qairtBuild = '2.52.0.261104';

/// Qualcomm's public download of [qairtBuild] (no login). Redirects once to
/// an API gateway that serves byte ranges.
final qairtZipUrl = Uri.parse(
  'https://softwarecenter.qualcomm.com/api/download/software/sdks/'
  'Qualcomm_AI_Runtime_Community/All/$qairtBuild/v$qairtBuild.zip',
);

/// Size of `v2.52.0.261104.zip` (read from a range response, 2026-11-25). A
/// range response for any other total is a different file, and is refused.
const qairtZipLength = 3036597557;

/// SHA-256 of each library as it sits in the zip, measured from the zip by
/// range reads on 2026-11-25. D3 test branch, candidate A: Google's LiteRT
/// v2.4.0 pair (QAIRT 2.52.0), not LiteRT bf49eb62's 2.51.1 pin; not yet
/// run on a QCS8275.
const qairtLinuxSha256 = {
  'libQnnHtp.so':
      '9e4255df5076183c1968f70b1fe7cbd9f3a6157a825a3a504f2b279b29f66092',
  'libQnnSystem.so':
      'eca36dc7b9708ac2084049fe782e1970622c68f2268b3769b958e105faa1023b',
  'libQnnHtpV68Stub.so':
      'bcab48b4301964216aa954fe4a28f167aaaed22ce3d66333d8195d36b30f4dec',
  'libQnnHtpV68Skel.so':
      '63d756cb824cecf85241913079a925a69b1398da43c432d9370cb0e148503cca',
  'libQnnHtpV69Stub.so':
      '0a531f10ee63d508b05a4a3d3338d793d5f2f34244c71f7fb61f454be5aeb66d',
  'libQnnHtpV69Skel.so':
      'a5a7d11eb221a2ee2215d886267c351e9223b71c55cccece63d6a22e16315688',
  'libQnnHtpV73Stub.so':
      '6debc0f68122f92602fc8c9393798a538f1bfd9c3e6a37d2dd815aab93735e1e',
  'libQnnHtpV73Skel.so':
      'e62cfd3e822b8a4ac06350f419912180ac4a3f2d3538e09e62874dfcedb92c44',
  'libQnnHtpV75Stub.so':
      '410e9366c89ffb049778373efd9f7bcc2f18f9dd44ea2ee82251297ef8c408d4',
  'libQnnHtpV75Skel.so':
      'd469c99cd295fc2d9fa5a576bc977ad78a42505afb12729b19028fd429e0f92f',
  'libQnnHtpV79Stub.so':
      '059cb56de97a046c34174f259c9690906f8a904730176ccfe20e06f12455270f',
  'libQnnHtpV79Skel.so':
      'f4fd254a5e1571a9c62e1e10c06228ff89a29c08168d67bcabf5fd7f6c8a69b3',
  'libQnnHtpV81Stub.so':
      'd24f43329332ee99b49a1de943829fb0f575fbbd41843c489b37679e8ea7256a',
  'libQnnHtpV81Skel.so':
      '7e7f3400b302d023e406b6f2581950ce4e6c456a0f460167fb3cae3c232c6610',
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
    notices: {for (final f in qairtNoticeFiles) f: ?entries[qairtEntryPath(f)]},
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
