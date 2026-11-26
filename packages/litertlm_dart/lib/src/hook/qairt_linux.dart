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
/// Its own release, not [qnnRuntimeVersion]: Linux has no Maven artifact, so
/// it can take the exact QAIRT LiteRT pins (`third_party/qairt/workspace.bzl`
/// at `bf49eb62`: 2.51.1.261002), which Maven Central does not carry for
/// Android. The Linux dispatch is built against the header slice
/// `fetch_qairt_sdk_slim.py` reads from this same zip, and
/// `build_qualcomm_dispatch.sh TARGET=linux_arm64` refuses an SDK of any other
/// release.
const qairtBuild = '2.51.1.261002';

/// Qualcomm's public download of [qairtBuild] (no login). Redirects once to
/// an API gateway that serves byte ranges.
final qairtZipUrl = Uri.parse(
  'https://softwarecenter.qualcomm.com/api/download/software/sdks/'
  'Qualcomm_AI_Runtime_Community/All/$qairtBuild/v$qairtBuild.zip',
);

/// Size of `v2.51.1.261002.zip` (read from a range response, 2026-11-25). A
/// range response for any other total is a different file, and is refused.
const qairtZipLength = 2971039746;

/// SHA-256 of each library as it sits in the zip, measured from the zip by
/// range reads on 2026-11-25. D3 test branch, candidate B: the exact QAIRT
/// LiteRT bf49eb62 pins; not yet run on a QCS8275.
const qairtLinuxSha256 = {
  'libQnnHtp.so':
      'bf77968b801cccca89dc3f99aca9894bab45980a2e3a4b6d629b022c8617beac',
  'libQnnSystem.so':
      '3c0238ace64db39a3c6b0c9e1aee01bfbf71baabad66e421408d044d01840203',
  'libQnnHtpV68Stub.so':
      '538fc29e04d83822d47083a79bde0e18cd37d08dd8f0da8f5a2f11f407fbe90a',
  'libQnnHtpV68Skel.so':
      'b6b2e99f7cec3ad7bd73a8b928fee2aa9fda7510a17bc783824a46c90ee6515e',
  'libQnnHtpV69Stub.so':
      'cd0335bfc63564a9c2a372bb6e24fe834083aa0de317ce3c0459e326f91c31b7',
  'libQnnHtpV69Skel.so':
      '2300b76f11e65f6593a44c786c92fdfee93163225a94aeae4e88a57ef0c686a7',
  'libQnnHtpV73Stub.so':
      'a714ca8e00c32e3aeb0bf38fb8797dee3068387e8dabcd63967fb752247fa11e',
  'libQnnHtpV73Skel.so':
      'c1e3e23ef676f092d69aa4a32301af78014ca19828a7020d56019d2eae832426',
  'libQnnHtpV75Stub.so':
      '9e81df5cd8c4a945adc8465d5568c7146ef2cec764ee1f185a49c51bcfcff1e2',
  'libQnnHtpV75Skel.so':
      '3514dd6a25842cd33a2d3168e42f2fcb89ade0631fd3299b839c6a4f758be990',
  'libQnnHtpV79Stub.so':
      'cf474e74bcc75dcb8bdbd2b232be232b58370450bd31e9ec5ed7f77068745bfd',
  'libQnnHtpV79Skel.so':
      '6ffe158665620af47011c6f41a45b89ae572038f31edc99c8d4e7e87e15b5206',
  'libQnnHtpV81Stub.so':
      'f5aad77022117dc238ae0407204a4366fa5b6026d73be249bf7cd079c77a76af',
  'libQnnHtpV81Skel.so':
      '839f1665f103982d3fb26bd3e9168f8c87f50101eb21d5a6ff9f22e31809a91b',
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
