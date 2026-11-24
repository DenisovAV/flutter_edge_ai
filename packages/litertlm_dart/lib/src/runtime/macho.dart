// One reader of a 64-bit Mach-O file's load commands, for the build hook (the
// header room the Dart SDK's install-name rewrite needs) and the macOS loader
// (which build of LiteRtLm a program carries, from the libraries it links).
// `dart:typed_data` only, so the hook can import it. Every read is
// bounds-checked; anything that is not a well-formed 64-bit little-endian
// Mach-O is a [FormatException].
//
// Package-private.

import 'dart:convert';
import 'dart:typed_data';

/// The size of a 64-bit Mach-O header (`mach_header_64`).
const machOHeaderSize = 32;

const _magic64 = 0xfeedfacf;
const _lcSegment64 = 0x19;
const _lcLoadDylib = 0xc;
const _lcLoadWeakDylib = 0x80000018;
const _lcReexportDylib = 0x8000001f;

/// One load command: its `cmd`, and where its bytes are.
typedef MachOLoadCommand = ({int cmd, int offset, int size});

/// How many bytes from the start of the file hold the header and the load
/// commands of [header], the file's first [machOHeaderSize] bytes or more.
/// Throws a [FormatException] for anything but a 64-bit little-endian
/// Mach-O, before any length is taken from it, and for `sizeofcmds` above
/// [machOMaxCommandsSize], before anything is allocated for it.
int machOHeaderAndCommandsLength(Uint8List header) {
  _checkMagic(header);
  final sizeofcmds = ByteData.sublistView(header).getUint32(20, Endian.little);
  if (sizeofcmds > machOMaxCommandsSize) {
    throw FormatException(
      'sizeofcmds of $sizeofcmds bytes, more than any library this reads',
    );
  }
  return machOHeaderSize + sizeofcmds;
}

/// The most load-command bytes [machOHeaderAndCommandsLength] accepts: a
/// read is sized by it, and libLiteRtLm's are under 4 KB (3,856 bytes in
/// native-v0.19.1-c).
const machOMaxCommandsSize = 1 << 20;

void _checkMagic(Uint8List bytes) {
  if (bytes.length < machOHeaderSize ||
      ByteData.sublistView(bytes).getUint32(0, Endian.little) != _magic64) {
    throw const FormatException('not a 64-bit little-endian Mach-O file');
  }
}

/// The load commands of [bytes], the start of a 64-bit Mach-O file through
/// its load commands at least. Each command must lie inside `sizeofcmds`
/// and inside [bytes].
List<MachOLoadCommand> machOLoadCommands(Uint8List bytes) {
  _checkMagic(bytes);
  final data = ByteData.sublistView(bytes);
  final ncmds = data.getUint32(16, Endian.little);
  final end = machOHeaderSize + data.getUint32(20, Endian.little);
  if (end > bytes.length) {
    throw const FormatException('the load commands run past the bytes read');
  }
  final commands = <MachOLoadCommand>[];
  var at = machOHeaderSize;
  for (var i = 0; i < ncmds; i++) {
    if (at + 8 > end) {
      throw const FormatException('a load command runs past sizeofcmds');
    }
    final cmd = data.getUint32(at, Endian.little);
    final size = data.getUint32(at + 4, Endian.little);
    if (size < 8 || at + size > end) {
      throw FormatException('load command $i has a bad size ($size)');
    }
    commands.add((cmd: cmd, offset: at, size: size));
    at += size;
  }
  return commands;
}

/// The free bytes between the load commands of [bytes] and its first
/// section: how much install_name_tool can grow them.
int machOHeaderSlack(Uint8List bytes) {
  final commands = machOLoadCommands(bytes);
  final data = ByteData.sublistView(bytes);
  var firstSection = bytes.length;
  for (final (:cmd, :offset, :size) in commands) {
    if (cmd != _lcSegment64) continue;
    // segment_command_64 is 72 bytes, each section_64 80.
    if (size < 72) {
      throw FormatException('an LC_SEGMENT_64 of $size bytes');
    }
    final nsects = data.getUint32(offset + 64, Endian.little);
    if (72 + nsects * 80 > size) {
      throw const FormatException('sections run past their segment');
    }
    for (var s = 0; s < nsects; s++) {
      // section_64: its file offset at byte 48.
      final at = data.getUint32(offset + 72 + s * 80 + 48, Endian.little);
      if (at != 0 && at < firstSection) firstSection = at;
    }
  }
  final sizeofcmds = data.getUint32(20, Endian.little);
  return firstSection - machOHeaderSize - sizeofcmds;
}

/// The install names of the dylibs [bytes] links (`LC_LOAD_DYLIB`, weak and
/// re-exported ones).
List<String> machOLinkedDylibs(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [
    for (final (:cmd, :offset, :size) in machOLoadCommands(bytes))
      if (cmd == _lcLoadDylib ||
          cmd == _lcLoadWeakDylib ||
          cmd == _lcReexportDylib)
        _lcStr(bytes, data, offset, size),
  ];
}

/// The string a `dylib_command` names: at its `name.offset` (byte 8), inside
/// the command, up to its NUL.
String _lcStr(Uint8List bytes, ByteData data, int offset, int size) {
  if (size < 24) throw FormatException('a dylib command of $size bytes');
  final at = data.getUint32(offset + 8, Endian.little);
  if (at < 24 || at >= size) {
    throw FormatException('a dylib name at $at in a command of $size bytes');
  }
  var end = offset + at;
  while (end < offset + size && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(offset + at, end), allowMalformed: true);
}
