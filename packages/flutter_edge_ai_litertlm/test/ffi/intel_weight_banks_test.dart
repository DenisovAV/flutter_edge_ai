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

  group('owner locks', () {
    const name = 'litert_ov_bank_0123456789abcdef.bin';
    File lock(String bankName, int ownerPid) =>
        File('${temp.path}/$bankName.$ownerPid.owner')..writeAsStringSync('');

    // POSIX deletes an open file, so a held lock is simulated: on Windows,
    // where the sweep runs, the delete of a lock someone holds is refused.
    bool Function(File) refusing(Set<String> held) => (f) {
      if (held.contains(f.uri.pathSegments.last)) return false;
      f.deleteSync();
      return true;
    };

    test('a bank whose locks all delete is its dead owner\'s, deleted even '
        'when fresh', () {
      final b = bank(name, modified: now, size: 7);
      final l = lock(name, 4242);

      expect(
        sweepStaleIntelWeightBanks(
          temp: temp,
          now: now,
          deleteLock: refusing({}),
        ),
        7,
      );
      expect(b.existsSync(), isFalse);
      expect(l.existsSync(), isFalse);
    });

    test('a bank with a held lock is a live process\'s, kept however old', () {
      final b = bank(name, modified: old);
      final l = lock(name, 4242);

      expect(
        sweepStaleIntelWeightBanks(
          temp: temp,
          now: now,
          deleteLock: refusing({'$name.4242.owner'}),
        ),
        0,
      );
      expect(b.existsSync(), isTrue);
      expect(l.existsSync(), isTrue);
    });

    test(
      'one live owner among dead ones keeps the bank; the dead locks go',
      () {
        final b = bank(name, modified: old);
        final dead = lock(name, 1);
        final live = lock(name, 2);

        expect(
          sweepStaleIntelWeightBanks(
            temp: temp,
            now: now,
            deleteLock: refusing({'$name.2.owner'}),
          ),
          0,
        );
        expect(b.existsSync(), isTrue);
        expect(dead.existsSync(), isFalse);
        expect(live.existsSync(), isTrue);
      },
    );

    test('a lock whose bank is gone is deleted', () {
      final l = lock(name, 4242);

      expect(
        sweepStaleIntelWeightBanks(
          temp: temp,
          now: now,
          deleteLock: refusing({}),
        ),
        0,
      );
      expect(l.existsSync(), isFalse);
    });

    test('the staged bank and its locks are left alone', () {
      final staged = bank(name, modified: old);
      final l = lock(name, 4242);

      expect(
        sweepStaleIntelWeightBanks(
          temp: temp,
          now: now,
          keep: staged.path,
          deleteLock: refusing({}),
        ),
        0,
      );
      expect(staged.existsSync(), isTrue);
      expect(l.existsSync(), isTrue);
    });

    test('a claim locks only the banks that appeared since the listing, and '
        'release removes its locks', () {
      bank(name, modified: old);
      final before = listIntelWeightBanks(temp: temp);
      const fresh = 'litert_ov_bank_fedcba9876543210.bin';
      bank(fresh, modified: now);

      final claim = IntelWeightBankClaim.newSince(before, temp: temp);
      expect(claim.banks, [fresh]);
      final mine = File('${temp.path}/$fresh.$pid.owner');
      expect(mine.existsSync(), isTrue);
      expect(File('${temp.path}/$name.$pid.owner').existsSync(), isFalse);

      claim.release();
      expect(mine.existsSync(), isFalse);
      expect(claim.banks, isEmpty);
    });
  });
}
