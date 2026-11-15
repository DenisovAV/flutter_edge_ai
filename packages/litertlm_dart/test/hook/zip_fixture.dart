import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A minimal zip writer, just enough to feed the reader: each entry stored or
/// raw-deflated, CRCs left zero (the reader trusts the archive-wide SHA256).
Uint8List buildZip(Map<String, List<int>> entries, {bool deflate = true}) {
  final body = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final e in entries.entries) {
    final name = utf8.encode(e.key);
    final payload = deflate ? ZLibEncoder(raw: true).convert(e.value) : e.value;
    final offset = body.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(8, deflate ? 8 : 0, Endian.little)
      ..setUint32(18, payload.length, Endian.little)
      ..setUint32(22, e.value.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    body
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(payload);
    final cd = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(10, deflate ? 8 : 0, Endian.little)
      ..setUint32(20, payload.length, Endian.little)
      ..setUint32(24, e.value.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(cd.buffer.asUint8List())
      ..add(name);
    count++;
  }
  final cdOffset = body.length;
  final cdBytes = central.takeBytes();
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  return (BytesBuilder()
        ..add(body.takeBytes())
        ..add(cdBytes)
        ..add(eocd.buffer.asUint8List()))
      .takeBytes();
}
