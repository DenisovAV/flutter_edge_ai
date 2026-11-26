// The one Mach-O load-command walker: the macOS loader's "what does LiteRtLm
// link". Malformed input is a FormatException,
// never a read past the bytes.
import 'dart:typed_data';

import 'package:litertlm_dart/src/runtime/macho.dart';
import 'package:test/test.dart';

/// A load command: [cmd], its [name] as an lc_str at [nameOffset] (24 by
/// default), padded to [size] (rounded up to 8 by default).
Uint8List _command(int cmd, String name, {int nameOffset = 24, int? size}) {
  final length = size ?? ((nameOffset + name.length + 1 + 7) & ~7);
  final b = ByteData(length)
    ..setUint32(0, cmd, Endian.little)
    ..setUint32(4, length, Endian.little)
    ..setUint32(8, nameOffset, Endian.little);
  final bytes = b.buffer.asUint8List();
  if (nameOffset < length) {
    bytes.setAll(nameOffset, name.codeUnits.take(length - nameOffset));
  }
  return bytes;
}

/// A 64-bit Mach-O: header + [commands] (+ [trailing] zero bytes).
Uint8List _machO(List<Uint8List> commands, {int trailing = 0, int? ncmds}) {
  final sizeofcmds = commands.fold<int>(0, (n, c) => n + c.length);
  final header = ByteData(32)
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(16, ncmds ?? commands.length, Endian.little)
    ..setUint32(20, sizeofcmds, Endian.little);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    for (final c in commands) ...c,
    ...List.filled(trailing, 0),
  ]);
}

void main() {
  test('the linked dylibs: plain, weak and re-exported, not the id', () {
    final file = _machO([
      _command(0xd, '@rpath/libLiteRtLm.dylib'),
      _command(0xc, '/usr/lib/libc++.1.dylib'),
      _command(0x80000018, '@rpath/lib/libLtGmcp.dylib'),
      _command(0x8000001f, '/usr/lib/libz.dylib'),
    ]);
    expect(machOLinkedDylibs(file), [
      '/usr/lib/libc++.1.dylib',
      '@rpath/lib/libLtGmcp.dylib',
      '/usr/lib/libz.dylib',
    ]);
    expect(machOHeaderAndCommandsLength(file), file.length);
  });

  group('malformed input is a FormatException', () {
    final fat = Uint8List.fromList([
      0xca,
      0xfe,
      0xba,
      0xbe,
      ...List.filled(28, 0),
    ]);
    final elf = Uint8List.fromList([
      0x7f,
      0x45,
      0x4c,
      0x46,
      ...List.filled(28, 0),
    ]);
    final cases = <String, Uint8List>{
      'a fat file': fat,
      'an ELF file': elf,
      'fewer bytes than a header': Uint8List(8),
      'commands cut short of sizeofcmds': () {
        final full = _machO([_command(0xc, '/usr/lib/libc++.1.dylib')]);
        return Uint8List.sublistView(full, 0, full.length - 8);
      }(),
      'a command running past sizeofcmds': _machO([
        _command(0xc, '/x'),
      ], ncmds: 2),
      'a name offset past its command': _machO([
        _command(0xc, '/x', nameOffset: 200, size: 32),
      ]),
      'a name offset inside the fixed part': _machO([
        _command(0xc, '/x', nameOffset: 8, size: 32),
      ]),
    };
    for (final MapEntry(key: what, value: bytes) in cases.entries) {
      test(what, () {
        expect(() => machOLinkedDylibs(bytes), throwsFormatException);
      });
    }

    test('a zero-size command', () {
      final bytes = _machO([_command(0xc, '/x')]);
      ByteData.sublistView(bytes).setUint32(36, 0, Endian.little);
      expect(() => machOLoadCommands(bytes), throwsFormatException);
    });

    test('a sizeofcmds no library has is refused before any read', () {
      final header = _machO([]);
      ByteData.sublistView(header).setUint32(20, (1 << 20) + 1, Endian.little);
      expect(() => machOHeaderAndCommandsLength(header), throwsFormatException);
      ByteData.sublistView(header).setUint32(20, 1 << 20, Endian.little);
      expect(machOHeaderAndCommandsLength(header), 32 + (1 << 20));
    });

    test('the header length is not taken from a non-Mach-O', () {
      expect(() => machOHeaderAndCommandsLength(fat), throwsFormatException);
    });
  });
}
