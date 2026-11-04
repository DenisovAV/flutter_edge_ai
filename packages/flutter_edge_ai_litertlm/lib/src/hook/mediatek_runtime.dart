// Opt-in MediaTek NPU dispatch for hook/build.dart.
//
// The MediaTek dispatch (libLiteRtDispatch_MediaTek.so) is LiteRT's Apache-2.0
// code, but it compiles against MediaTek's NeuroPilot SDK, whose licence lets
// it be redistributed only in object code "as incorporated in Your software
// application", never on a standalone basis, and never under open-source
// terms. So this package neither builds nor carries it. An app that sets
// `mediatek_npu: true` gets Google's own build of it at build time, from
// `com.google.ai.edge.litert:litert-npu-runtime-mediatek` on Google Maven, and
// it reaches users only inside that app. The NeuroPilot runtime itself is
// never bundled: the dispatch opens it from the device.
//
// The AAR also carries LiteRT's MediaTek compiler plugin (on-device
// compilation); it is left out — only bundles compiled ahead of time for a
// MediaTek SoC run here.
//
// Everything here works on bytes and files with no hook types, so it can be
// unit-tested without running a build. It reuses the AAR reader and the cache
// writer of the QNN runtime (qnn_runtime.dart).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/hook/qnn_runtime.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';

/// The `litert-npu-runtime-mediatek` release fetched for `mediatek_npu: true`.
///
/// Built by Google from LiteRT 2.3.0. This package's LiteRT pin (26895c9f)
/// is 16 commits before v2.3.0 on the same branch, and the dispatch ABI —
/// `litert/vendors/c/litert_dispatch.h`, `litert_dispatch_api.h`,
/// `litert/c/options/litert_mediatek_options.h`, `litert_common.h`,
/// `litert_any.h` — is byte-identical at both. Re-check those files when the
/// pin or this version moves.
const mediatekRuntimeVersion = '2.3.0';

/// SHA256 of `litert-npu-runtime-mediatek-2.3.0.aar` as published on Google
/// Maven (its SHA1 matches Maven's own `.sha1`, 34170a8d…).
const mediatekRuntimeSha256 =
    '949fcd3a40d597f07473eb8d6b4d89ab6343b5a8fd2d21c118e2855e613c4587';

/// Maven repository the AAR comes from unless the app names a mirror.
const mediatekDefaultMavenBase = 'https://dl.google.com/dl/android/maven2';

/// Bumped whenever what this file writes into the cache changes for the same
/// AAR, so an older cache is not reused.
const mediatekCacheFormat = 1;

/// URL of the MediaTek dispatch AAR under the Maven repository [mavenBase].
Uri mediatekRuntimeAarUrl(String mavenBase) {
  final base = mavenBase.endsWith('/')
      ? mavenBase.substring(0, mavenBase.length - 1)
      : mavenBase;
  return Uri.parse(
    '$base/com/google/ai/edge/litert/litert-npu-runtime-mediatek/'
    '$mediatekRuntimeVersion/'
    'litert-npu-runtime-mediatek-$mediatekRuntimeVersion.aar',
  );
}

/// Directory name of one immutable cache entry.
String mediatekCacheEntryName() =>
    '$mediatekRuntimeVersion-${mediatekRuntimeSha256.substring(0, 8)}'
    '-p$mediatekCacheFormat';

/// File names of the libraries a complete cache entry holds.
List<String> get mediatekLibFileNames => [
  for (final n in mediatekNpuLibs) androidLibFileName(n),
];

/// Makes the dispatch from the AAR ready to bundle: refused unless every
/// PT_LOAD is 16 KB-aligned (it is at 2.3.0), since Google Play rejects an
/// app bundling a library that is not.
Uint8List prepareMediatekLibrary(String fileName, Uint8List bytes) {
  if (!hasLoadAlignment16K(bytes, name: fileName, machine: emAarch64)) {
    throw FormatException(
      '$fileName from litert-npu-runtime-mediatek $mediatekRuntimeVersion is '
      'not 16 KB-aligned; Google Play would reject every app bundling it',
    );
  }
  return bytes;
}

/// Writes the dispatch extracted from the verified [aar] into a new directory
/// under [cacheRoot] and promotes it to the entry for this version, returning
/// that entry. Google's LICENSE and THIRD_PARTY_NOTICE.txt travel with it.
Directory promoteMediatekCache(Directory cacheRoot, File aar) =>
    writeQnnCacheEntry(
      cacheRoot,
      mediatekCacheEntryName(),
      mediatekLibFileNames,
      () {
        final entries = extractZipEntriesFromFile(aar, {
          for (final f in mediatekLibFileNames) 'jni/arm64-v8a/$f',
        });
        return {
          for (final f in mediatekLibFileNames)
            f: prepareMediatekLibrary(f, entries['jni/arm64-v8a/$f']!),
        };
      },
      () =>
          extractZipEntriesFromFile(aar, {'LICENSE', 'THIRD_PARTY_NOTICE.txt'}),
    );
