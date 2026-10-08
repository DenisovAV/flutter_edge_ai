// Opt-in Qualcomm NPU stack for hook/build.dart.
//
// Qualcomm's QNN runtime (libQnnHtp, libQnnSystem, the per-Hexagon Stub/Skel
// pairs) is Qualcomm's code, licensed so that it may be redistributed only "as
// incorporated in Your software application" and never "on a standalone
// basis". So this package does not carry it in its own native release. An app
// that sets `qualcomm_npu: true` gets it at build time from Qualcomm's own
// publication on Maven Central (com.qualcomm.qti:qnn-runtime), and it reaches
// users only inside that app.
//
// Everything here works on bytes and files with no hook types, so it can be
// unit-tested without running a build. The network fetch is injected.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';

/// The QNN runtime release fetched for `qualcomm_npu: true`.
///
/// Must be the QAIRT release the Qualcomm dispatch is built against — LiteRT
/// pins it in `third_party/qairt/workspace.bzl` (2.50.0.260828 at the v0.18.0
/// pin), and `build_qualcomm_dispatch.sh` refuses to build when the two
/// disagree. A runtime older than the dispatch fails only on real hardware
/// (`Qnn System library version … is mismatched`).
const qnnRuntimeVersion = '2.50.0';

/// SHA256 of `qnn-runtime-2.50.0.aar` as published on Maven Central (its SHA1
/// matches Maven's own `.sha1`).
const qnnRuntimeSha256 =
    'b507656e4031d8aa6a7ab0fecf725b941096737ad7440ad7ea288f7c9cc9d743';

/// Maven repository the AAR comes from unless the app names a mirror.
const qnnDefaultMavenBase = 'https://repo1.maven.org/maven2';

/// Bumped whenever what this file writes into the cache changes for the same
/// AAR (the extraction set, the patch, the marker), so an older cache is not
/// reused. 2: the marker records each library's SHA-256, not only its size.
const qnnCacheFormat = 2;

/// URL of the QNN runtime AAR under the Maven repository [mavenBase].
Uri qnnRuntimeAarUrl(String mavenBase) {
  final base = mavenBase.endsWith('/')
      ? mavenBase.substring(0, mavenBase.length - 1)
      : mavenBase;
  return Uri.parse(
    '$base/com/qualcomm/qti/qnn-runtime/$qnnRuntimeVersion/'
    'qnn-runtime-$qnnRuntimeVersion.aar',
  );
}

/// Reads a boolean user-define.
///
/// Absent means false. A pubspec gives a real bool; a command-line define
/// arrives as the string `true` or `false`. Anything else is a typo in the
/// app's pubspec, and a typo must not silently mean "off" — the developer
/// asked for something and would get a build that quietly lacks it.
bool readBoolUserDefine(Object? value, String key) => switch (value) {
  null => false,
  final bool b => b,
  'true' => true,
  'false' => false,
  _ => throw FormatException(
    'hooks.user_defines.flutter_edge_ai_litertlm.$key must be true or false, '
    'got ${value.runtimeType} "$value"',
  ),
};

// ---------------------------------------------------------------------------
// ZIP (an AAR is a plain zip)
// ---------------------------------------------------------------------------

/// Reads [length] bytes at [offset] of some archive.
typedef ReadAt = Uint8List Function(int offset, int length);

/// Returns the bytes of each entry in [entryNames] from a zip archive of
/// [archiveLength] bytes read through [readAt].
///
/// A minimal reader for what an AAR is: stored or deflated entries, under
/// 4 GB and 65535 entries. Integrity comes from the SHA256 the caller verified
/// over the whole archive, so per-entry CRCs are not checked. Throws
/// [FormatException] for a missing entry or anything outside that shape —
/// never returns a partial map.
Map<String, Uint8List> extractZipEntriesWith(
  ReadAt readAt,
  int archiveLength,
  Set<String> entryNames,
) {
  // End-of-central-directory record: 22 bytes plus a comment of up to 64 KB.
  final tailLength = archiveLength < 22 + 0xFFFF ? archiveLength : 22 + 0xFFFF;
  final tailStart = archiveLength - tailLength;
  final tail = readAt(tailStart, tailLength);
  final t = ByteData.sublistView(tail);
  var eocd = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (t.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('not a zip archive (no EOCD)');
  final count = t.getUint16(eocd + 10, Endian.little);
  final cdSize = t.getUint32(eocd + 12, Endian.little);
  final cdOffset = t.getUint32(eocd + 16, Endian.little);
  if (count == 0xFFFF || cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) {
    throw const FormatException('zip64 archives are not supported');
  }
  if (cdOffset + cdSize > archiveLength) {
    throw const FormatException('zip central directory runs past the end');
  }

  final cd = readAt(cdOffset, cdSize);
  final c = ByteData.sublistView(cd);
  final out = <String, Uint8List>{};
  var p = 0;
  for (var i = 0; i < count; i++) {
    if (p + 46 > cd.length || c.getUint32(p, Endian.little) != 0x02014b50) {
      throw FormatException('corrupt zip central directory entry $i');
    }
    final method = c.getUint16(p + 10, Endian.little);
    final compressedSize = c.getUint32(p + 20, Endian.little);
    final size = c.getUint32(p + 24, Endian.little);
    final nameLen = c.getUint16(p + 28, Endian.little);
    final extraLen = c.getUint16(p + 30, Endian.little);
    final commentLen = c.getUint16(p + 32, Endian.little);
    final localOffset = c.getUint32(p + 42, Endian.little);
    final name = utf8.decode(
      Uint8List.sublistView(cd, p + 46, p + 46 + nameLen),
    );
    p += 46 + nameLen + extraLen + commentLen;
    if (!entryNames.contains(name)) continue;

    final local = readAt(localOffset, 30);
    final l = ByteData.sublistView(local);
    if (l.getUint32(0, Endian.little) != 0x04034b50) {
      throw FormatException('corrupt zip local header for $name');
    }
    final start =
        localOffset +
        30 +
        l.getUint16(26, Endian.little) +
        l.getUint16(28, Endian.little);
    if (start + compressedSize > archiveLength) {
      throw FormatException('$name runs past the end of the archive');
    }
    final raw = readAt(start, compressedSize);
    final Uint8List entry = switch (method) {
      0 => raw,
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(raw)),
      _ => throw FormatException(
        '$name uses zip compression method $method (only stored/deflate)',
      ),
    };
    if (entry.length != size) {
      throw FormatException(
        '$name inflated to ${entry.length} bytes, the archive says $size',
      );
    }
    out[name] = entry;
  }
  final missing = entryNames.difference(out.keys.toSet());
  if (missing.isNotEmpty) {
    throw FormatException('missing from the archive: ${missing.join(', ')}');
  }
  return out;
}

/// [extractZipEntriesWith] over an in-memory archive.
Map<String, Uint8List> extractZipEntries(
  Uint8List bytes,
  Set<String> entryNames,
) => extractZipEntriesWith(
  (o, n) {
    if (o < 0 || o + n > bytes.length) {
      throw const FormatException('read past the end of the archive');
    }
    return Uint8List.sublistView(bytes, o, o + n);
  },
  bytes.length,
  entryNames,
);

/// [extractZipEntriesWith] over a file, reading only the central directory and
/// the wanted entries — not the whole 71 MB AAR into memory.
Map<String, Uint8List> extractZipEntriesFromFile(
  File file,
  Set<String> entryNames,
) {
  final raf = file.openSync();
  try {
    final length = raf.lengthSync();
    return extractZipEntriesWith(
      (o, n) {
        if (o < 0 || o + n > length) {
          throw const FormatException('read past the end of the archive');
        }
        raf.setPositionSync(o);
        final b = raf.readSync(n);
        if (b.length != n) {
          throw const FormatException('short read from the archive');
        }
        return b;
      },
      length,
      entryNames,
    );
  } finally {
    raf.closeSync();
  }
}

// ---------------------------------------------------------------------------
// ELF program headers
// ---------------------------------------------------------------------------

/// The page size Google Play requires every bundled ELF to be aligned to.
const pageAlign16K = 0x4000;

/// `e_machine` of the Hexagon DSP images (the Skels).
const emHexagon = 164;

/// `e_machine` of the arm64 libraries.
const emAarch64 = 183;

class _ElfLoads {
  _ElfLoads(this.data, this.is64, this.headers);

  final ByteData data;
  final bool is64;

  /// Byte offsets of the PT_LOAD program headers.
  final List<int> headers;

  int _word(int at) => is64
      ? data.getUint64(at, Endian.little)
      : data.getUint32(at, Endian.little);

  int offset(int h) => _word(h + (is64 ? 0x08 : 0x04));
  int vaddr(int h) => _word(h + (is64 ? 0x10 : 0x08));
  int align(int h) => _word(h + (is64 ? 0x30 : 0x1C));
  void setAlign(int h, int v) => is64
      ? data.setUint64(h + 0x30, v, Endian.little)
      : data.setUint32(h + 0x1C, v, Endian.little);
}

/// Parses and validates the PT_LOAD headers of a little-endian ELF.
///
/// Refuses anything that is not what the QNN libraries are, rather than
/// patching bytes at a guessed offset: the class must be ELF32/ELF64, the
/// data little-endian, `e_machine` [machine], the program-header table inside
/// the file with a sane entry size, at least one PT_LOAD, and every alignment
/// a power of two.
_ElfLoads _parseElf(
  Uint8List elf, {
  required String name,
  required int machine,
}) {
  if (elf.length < 0x34 ||
      elf[0] != 0x7f ||
      elf[1] != 0x45 ||
      elf[2] != 0x4c ||
      elf[3] != 0x46) {
    throw FormatException('$name is not an ELF file');
  }
  final cls = elf[4];
  if (cls != 1 && cls != 2) {
    throw FormatException('$name has an unknown ELF class $cls');
  }
  if (elf[5] != 1) throw FormatException('$name is not little-endian');
  final is64 = cls == 2;
  if (is64 && elf.length < 0x40) {
    throw FormatException('$name is too short for an ELF64 header');
  }
  final data = ByteData.sublistView(elf);
  final eMachine = data.getUint16(0x12, Endian.little);
  if (eMachine != machine) {
    throw FormatException('$name has e_machine $eMachine, expected $machine');
  }
  final phoff = is64
      ? data.getUint64(0x20, Endian.little)
      : data.getUint32(0x1C, Endian.little);
  final phentsize = data.getUint16(is64 ? 0x36 : 0x2A, Endian.little);
  final phnum = data.getUint16(is64 ? 0x38 : 0x2C, Endian.little);
  final minEntry = is64 ? 0x38 : 0x20;
  if (phentsize < minEntry) {
    throw FormatException('$name has program-header entries of $phentsize B');
  }
  if (phoff + phentsize * phnum > elf.length) {
    throw FormatException('$name program-header table runs past the file');
  }
  final loads = <int>[];
  for (var i = 0; i < phnum; i++) {
    final o = phoff + i * phentsize;
    if (data.getUint32(o, Endian.little) == 1) loads.add(o); // PT_LOAD
  }
  if (loads.isEmpty) throw FormatException('$name has no PT_LOAD segment');
  final parsed = _ElfLoads(data, is64, loads);
  for (final h in loads) {
    final a = parsed.align(h);
    if (a > 1 && (a & (a - 1)) != 0) {
      throw FormatException(
        '$name has a PT_LOAD align 0x${a.toRadixString(16)}',
      );
    }
  }
  return parsed;
}

/// Raises every PT_LOAD `p_align` below 16 KB to 16 KB, in place.
///
/// Google Play rejects an APK in which any `.so` has a PT_LOAD aligned below
/// 16 KB, and Qualcomm ships the Hexagon Skel blobs at 0x1000 — on Maven as in
/// the QAIRT SDK. The Skels are DSP images loaded by the DSP's own loader
/// through FastRPC and never mapped by the kernel, so this is metadata only.
/// It is sound exactly when each PT_LOAD keeps `p_vaddr ≡ p_offset (mod 16K)`;
/// a blob that breaks that would stop loading, so it is refused with
/// [FormatException] rather than patched, and nothing is changed.
///
/// Returns whether anything changed.
bool raiseLoadAlignmentTo16K(
  Uint8List elf, {
  String name = 'ELF',
  int machine = emHexagon,
}) {
  final e = _parseElf(elf, name: name, machine: machine);
  if (e.headers.every((h) => e.align(h) >= pageAlign16K)) return false;
  final broken = [
    for (final h in e.headers)
      if ((e.vaddr(h) - e.offset(h)) % pageAlign16K != 0)
        'offset 0x${e.offset(h).toRadixString(16)} '
            'vaddr 0x${e.vaddr(h).toRadixString(16)}',
  ];
  if (broken.isNotEmpty) {
    throw FormatException(
      '$name cannot be 16 KB-aligned in place: p_vaddr and p_offset are not '
      'congruent mod 16K for ${broken.join('; ')}',
    );
  }
  for (final h in e.headers) {
    if (e.align(h) < pageAlign16K) e.setAlign(h, pageAlign16K);
  }
  return true;
}

/// Whether every PT_LOAD of [elf] is aligned to at least 16 KB.
bool hasLoadAlignment16K(
  Uint8List elf, {
  String name = 'ELF',
  required int machine,
}) {
  final e = _parseElf(elf, name: name, machine: machine);
  return e.headers.every((h) => e.align(h) >= pageAlign16K);
}

/// Makes one QNN library from the AAR ready to bundle.
///
/// Only the four Hexagon Skels are patched; every other library is arm64 and
/// must already be 16 KB-aligned (all are at 2.50.0) — if a future AAR is
/// not, the build fails instead of shipping an APK Play rejects (#529).
Uint8List prepareQnnLibrary(String fileName, Uint8List bytes) {
  final out = Uint8List.fromList(bytes);
  if (fileName.endsWith('Skel.so')) {
    raiseLoadAlignmentTo16K(out, name: fileName, machine: emHexagon);
    if (!hasLoadAlignment16K(out, name: fileName, machine: emHexagon)) {
      throw StateError('$fileName is not 16 KB-aligned after patching');
    }
  } else if (!hasLoadAlignment16K(out, name: fileName, machine: emAarch64)) {
    throw FormatException(
      '$fileName from qnn-runtime $qnnRuntimeVersion is not 16 KB-aligned; '
      'Google Play would reject every app bundling it',
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/// The marker written last into a complete cache directory: file name →
/// {size, sha256}.
const qnnCacheMarker = '.complete';

/// Prefix of the per-download directory the hook fetches the AAR into.
const qnnDownloadTempPrefix = '.dl-';

/// Prefix of the directory a cache entry is prepared in before its rename.
const qnnPrepareTempPrefix = '.tmp-';

/// Age after which a temp directory under the cache root is a leftover of a
/// killed build (Ctrl-C, an OOM-killed CI job), not one still in progress.
const qnnStaleTempAge = Duration(days: 1);

/// Directory name of one immutable cache entry.
String qnnCacheEntryName() =>
    '$qnnRuntimeVersion-${qnnRuntimeSha256.substring(0, 8)}-p$qnnCacheFormat';

/// Modification time of every library in a cache entry.
///
/// The hook records these files as dependencies, and hooks_runner reports a
/// dependency modified after the build started as "File modified during
/// build. Build must be rerun." — which every file an entry's first build
/// writes would be. The main native bundle escapes it because `tar` restores
/// the archive's times; this does the same with one fixed instant, the zip
/// format's epoch. The dependency hash itself compares content, not time.
final qnnCacheFileTime = DateTime.utc(1980);

/// File names of the libraries a complete cache entry holds.
List<String> get qnnLibFileNames => [
  for (final n in qnnRuntimeLibs) androidLibFileName(n),
];

/// Whether [dir] holds a complete, intact cache entry: the marker lists every
/// library, and each file has the recorded size and SHA-256.
///
/// The hash, not only the size: these are executables the app ships, reused
/// for every later build, and a same-length change — a flipped byte, a cache
/// restored from somewhere else — would otherwise pass forever without ever
/// meeting the AAR's checksum again. Hashing the ~83 MB costs a fraction of a
/// second, and only on the builds where the hook runs at all.
bool isCompleteQnnCache(Directory dir) {
  final marker = File('${dir.path}/$qnnCacheMarker');
  if (!marker.existsSync()) return false;
  final Map<String, Object?> recorded;
  try {
    recorded = (jsonDecode(marker.readAsStringSync()) as Map)
        .cast<String, Object?>();
  } on Object {
    return false;
  }
  for (final name in qnnLibFileNames) {
    final entry = recorded[name];
    if (entry is! Map) return false;
    final size = entry['size'], hash = entry['sha256'];
    final f = File('${dir.path}/$name');
    if (size is! int || hash is! String) return false;
    if (!f.existsSync() || f.lengthSync() != size) return false;
    if (sha256.convert(f.readAsBytesSync()).toString() != hash) return false;
  }
  return true;
}

/// Writes the libraries extracted from the verified [aar] into a new
/// directory under [cacheRoot] and promotes it to the entry for this
/// version, returning that entry.
///
/// Safe against concurrent builds sharing the cache: an exclusive lock file
/// serialises writers, the work happens in a fresh `mkdtemp` directory, every
/// file is flushed before the marker is written last, and a valid entry is
/// never rewritten or deleted.
Directory promoteQnnCache(Directory cacheRoot, File aar) {
  cacheRoot.createSync(recursive: true);
  final target = Directory('${cacheRoot.path}/${qnnCacheEntryName()}');
  final lock = File('${cacheRoot.path}/.lock').openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.blockingExclusive);
    removeStaleQnnTemps(cacheRoot);
    if (isCompleteQnnCache(target)) return target;

    final entries = extractZipEntriesFromFile(aar, {
      for (final f in qnnLibFileNames) 'jni/arm64-v8a/$f',
    });
    final tmp = cacheRoot.createTempSync(qnnPrepareTempPrefix);
    try {
      final recorded = <String, Map<String, Object>>{};
      for (final f in qnnLibFileNames) {
        final bytes = prepareQnnLibrary(f, entries['jni/arm64-v8a/$f']!);
        final out = File('${tmp.path}/$f').openSync(mode: FileMode.write);
        try {
          out
            ..writeFromSync(bytes)
            ..flushSync();
        } finally {
          out.closeSync();
        }
        File('${tmp.path}/$f').setLastModifiedSync(qnnCacheFileTime);
        recorded[f] = {
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        };
      }
      // Qualcomm's own LICENSE.pdf and NOTICE.txt travel with the libraries.
      final notices = extractZipEntriesFromFile(aar, {
        'LICENSE.pdf',
        'NOTICE.txt',
      });
      for (final e in notices.entries) {
        File('${tmp.path}/${e.key}').writeAsBytesSync(e.value, flush: true);
      }
      File(
        '${tmp.path}/$qnnCacheMarker',
      ).writeAsStringSync(jsonEncode(recorded), flush: true);

      if (target.existsSync()) {
        // Not complete (checked above, under the lock): a crash mid-write of an
        // older run. Nothing can be using it, so it can go.
        target.deleteSync(recursive: true);
      }
      tmp.renameSync(target.path);
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
    if (!isCompleteQnnCache(target)) {
      throw StateError(
        'QNN cache at ${target.path} is incomplete after writing',
      );
    }
    return target;
  } finally {
    lock.closeSync();
  }
}

/// Deletes temp directories under [cacheRoot] that a killed build left behind
/// (71-83 MB each). Only old ones: a young one may be another build's work in
/// progress, since downloads run outside the lock.
void removeStaleQnnTemps(Directory cacheRoot, {DateTime? now}) {
  final cutoff = (now ?? DateTime.now()).subtract(qnnStaleTempAge);
  for (final e in cacheRoot.listSync(followLinks: false)) {
    if (e is! Directory) continue;
    final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (!name.startsWith(qnnDownloadTempPrefix) &&
        !name.startsWith(qnnPrepareTempPrefix)) {
      continue;
    }
    try {
      if (e.statSync().modified.isBefore(cutoff)) e.deleteSync(recursive: true);
    } on FileSystemException {
      // Housekeeping only; the entry being promoted does not depend on it.
    }
  }
}
