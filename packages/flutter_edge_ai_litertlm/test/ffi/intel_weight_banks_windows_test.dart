@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/intel_weight_banks.dart';
import 'package:flutter_test/flutter_test.dart';

// The premise the claim rests on, with the real delete: Windows refuses to
// delete a lock file a live handle holds. intel_weight_banks_test.dart
// injects that answer; this holds it to the system.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('banks_win_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a held lock keeps its bank through a sweep; released, both go', () {
    final bank = File('${dir.path}\\litert_ov_bank_0123456789abcdef.bin')
      ..writeAsBytesSync([1, 2, 3]);
    final claim = IntelWeightBankClaim.newSince({}, {bank.path});
    expect(claim.banks, [bank.path]);
    final lock = File('${bank.path}.$pid.owner');
    expect(lock.existsSync(), isTrue);
    expect(() => lock.deleteSync(), throwsA(isA<FileSystemException>()));

    // A boot after the bank was written: only the lock protects it.
    final later = DateTime.now().add(const Duration(hours: 1));
    sweepStaleIntelWeightBanks(dirs: [dir], bootedAt: () => later);
    expect(bank.existsSync(), isTrue);
    expect(lock.existsSync(), isTrue);

    claim.release();
    expect(lock.existsSync(), isFalse);
    sweepStaleIntelWeightBanks(dirs: [dir], bootedAt: () => later);
    expect(bank.existsSync(), isFalse);
  });
}
