import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/intel_weight_banks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  final now = DateTime(2026, 10, 20, 12);
  final old = now.subtract(const Duration(hours: 1));

  setUp(() => temp = Directory.systemTemp.createTempSync('ov_banks_'));
  tearDown(() => temp.deleteSync(recursive: true));

  File bank(String name, {required DateTime modified, int size = 4}) =>
      File('${temp.path}/$name')
        ..writeAsBytesSync(List.filled(size, 0))
        ..setLastModifiedSync(modified);

  test('deletes old banks and reports the bytes freed', () {
    final a = bank('litert_ov_bank_0123456789abcdef.bin', modified: old);
    final b = bank(
      'litert_ov_bank_fedcba9876543210.bin',
      modified: old,
      size: 10,
    );

    expect(sweepStaleIntelWeightBanks(temp: temp, now: now), 14);
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
  });

  test('keeps a bank written in the last ten minutes', () {
    final fresh = bank(
      'litert_ov_bank_0123456789abcdef.bin',
      modified: now.subtract(const Duration(minutes: 9)),
    );

    expect(sweepStaleIntelWeightBanks(temp: temp, now: now), 0);
    expect(fresh.existsSync(), isTrue);
  });

  test('keeps the bank an app staged itself', () {
    final staged = bank('litert_ov_bank_0123456789abcdef.bin', modified: old);

    expect(
      sweepStaleIntelWeightBanks(temp: temp, now: now, keep: staged.path),
      0,
    );
    expect(staged.existsSync(), isTrue);
  });

  test('touches only files named as the dispatch names banks', () {
    final others = [
      bank('litert_ov_bank_0123.bin', modified: old),
      bank('litert_ov_bank_0123456789abcdef.bin.tmp', modified: old),
      bank('litert_ov_bank_XYZ456789abcdef0.bin', modified: old),
      bank('model.litertlm', modified: old),
    ];
    Directory('${temp.path}/litert_ov_bank_0123456789abcdef.bin').createSync();

    expect(sweepStaleIntelWeightBanks(temp: temp, now: now), 0);
    for (final f in others) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }
  });

  test('a missing temp directory frees nothing', () {
    expect(
      sweepStaleIntelWeightBanks(
        temp: Directory('${temp.path}/missing'),
        now: now,
      ),
      0,
    );
  });
}
