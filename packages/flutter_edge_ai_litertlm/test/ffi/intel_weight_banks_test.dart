import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/intel_weight_banks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  final boot = DateTime(2026, 10, 20, 12);
  final beforeBoot = boot.subtract(const Duration(hours: 1));
  final afterBoot = boot.add(const Duration(hours: 1));

  setUp(() => temp = Directory.systemTemp.createTempSync('ov_banks_'));
  tearDown(() => temp.deleteSync(recursive: true));

  File bank(String name, {required DateTime modified, int size = 4}) =>
      File('${temp.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(List.filled(size, 0))
        ..setLastModifiedSync(modified);

  // POSIX deletes an open file, so a held lock is simulated: on Windows,
  // where the sweep runs, the delete of a lock someone holds is refused
  // (intel_weight_banks_windows_test.dart holds the real one to that).
  bool Function(File) refusing(Set<String> held) => (f) {
    if (held.contains(f.uri.pathSegments.last)) return false;
    f.deleteSync();
    return true;
  };

  int sweep({
    DateTime? bootedAt,
    bool noBootTime = false,
    String? keep,
    bool Function(File)? deleteLock,
    List<Directory>? dirs,
  }) => sweepStaleIntelWeightBanks(
    dirs: dirs ?? [temp],
    bootedAt: () => noBootTime ? null : bootedAt ?? boot,
    keep: keep,
    deleteLock: deleteLock ?? refusing({}),
  );

  test('deletes unclaimed banks written before the boot, and reports the '
      'bytes freed', () {
    final a = bank('litert_ov_bank_0123456789abcdef.bin', modified: beforeBoot);
    final b = bank(
      'litert_ov_bank_fedcba9876543210.bin',
      modified: beforeBoot,
      size: 10,
    );

    expect(sweep(), 14);
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
  });

  test('keeps an unclaimed bank written since the boot, however old: its '
      'process may still run', () {
    final live = bank(
      'litert_ov_bank_0123456789abcdef.bin',
      modified: afterBoot,
    );

    expect(sweep(), 0);
    expect(live.existsSync(), isTrue);
  });

  test('without a boot time, keeps every unclaimed bank', () {
    final b = bank('litert_ov_bank_0123456789abcdef.bin', modified: beforeBoot);

    expect(sweep(noBootTime: true), 0);
    expect(b.existsSync(), isTrue);
  });

  test('keeps the bank an app staged itself', () {
    final staged = bank(
      'litert_ov_bank_0123456789abcdef.bin',
      modified: beforeBoot,
    );

    expect(sweep(keep: staged.path), 0);
    expect(staged.existsSync(), isTrue);
  });

  test('knows the staged bank by the file, not by how its path is spelled', () {
    final staged = bank(
      'litert_ov_bank_0123456789abcdef.bin',
      modified: beforeBoot,
    );
    Directory('${temp.path}/sub').createSync();
    final respelled = '${temp.path}/sub/../litert_ov_bank_0123456789abcdef.bin';

    expect(sweep(keep: respelled), 0);
    expect(staged.existsSync(), isTrue);
  });

  test('touches only files named as the dispatch names banks', () {
    final others = [
      bank('litert_ov_bank_0123.bin', modified: beforeBoot),
      bank('litert_ov_bank_0123456789abcdef.bin.tmp', modified: beforeBoot),
      bank('litert_ov_bank_XYZ456789abcdef0.bin', modified: beforeBoot),
      bank('model.litertlm', modified: beforeBoot),
    ];
    Directory('${temp.path}/litert_ov_bank_0123456789abcdef.bin').createSync();

    expect(sweep(), 0);
    for (final f in others) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }
  });

  test('a missing temp directory frees nothing, and the next one is still '
      'swept', () {
    final b = bank('litert_ov_bank_0123456789abcdef.bin', modified: beforeBoot);

    expect(sweep(dirs: [Directory('${temp.path}/missing'), temp]), 4);
    expect(b.existsSync(), isFalse);
  });

  group('owner locks', () {
    const name = 'litert_ov_bank_0123456789abcdef.bin';
    File lock(String bankName, int ownerPid) =>
        File('${temp.path}/$bankName.$ownerPid.owner')..writeAsStringSync('');

    test('a bank whose locks all delete is its dead owner\'s, deleted even '
        'when written since the boot', () {
      final b = bank(name, modified: afterBoot, size: 7);
      final l = lock(name, 4242);

      expect(sweep(deleteLock: refusing({})), 7);
      expect(b.existsSync(), isFalse);
      expect(l.existsSync(), isFalse);
    });

    test('a bank with a held lock is a live process\'s, kept however old', () {
      final b = bank(name, modified: beforeBoot);
      final l = lock(name, 4242);

      expect(sweep(deleteLock: refusing({'$name.4242.owner'})), 0);
      expect(b.existsSync(), isTrue);
      expect(l.existsSync(), isTrue);
    });

    test(
      'one live owner among dead ones keeps the bank; the dead locks go',
      () {
        final b = bank(name, modified: beforeBoot);
        final dead = lock(name, 1);
        final live = lock(name, 2);

        expect(sweep(deleteLock: refusing({'$name.2.owner'})), 0);
        expect(b.existsSync(), isTrue);
        expect(dead.existsSync(), isFalse);
        expect(live.existsSync(), isTrue);
      },
    );

    test('a lock whose bank is gone is deleted', () {
      final l = lock(name, 4242);

      expect(sweep(deleteLock: refusing({})), 0);
      expect(l.existsSync(), isFalse);
    });

    test('the staged bank and its locks are left alone', () {
      final staged = bank(name, modified: beforeBoot);
      final l = lock(name, 4242);

      expect(sweep(keep: staged.path, deleteLock: refusing({})), 0);
      expect(staged.existsSync(), isTrue);
      expect(l.existsSync(), isTrue);
    });

    test('a claim locks only the banks that appeared since the listing, and '
        'release removes its locks', () {
      final kept = bank(name, modified: beforeBoot);
      final before = listIntelWeightBanks(dirs: [temp]);
      const fresh = 'litert_ov_bank_fedcba9876543210.bin';
      final freshBank = bank(fresh, modified: afterBoot);

      final claim = IntelWeightBankClaim.newSince(
        before,
        listIntelWeightBanks(dirs: [temp]),
      );
      // Before tearDown: on Windows a held lock keeps the directory.
      addTearDown(claim.release);
      expect(claim.banks, [freshBank.path]);
      final mine = File('${freshBank.path}.$pid.owner');
      expect(mine.existsSync(), isTrue);
      expect(File('${kept.path}.$pid.owner').existsSync(), isFalse);

      claim.release();
      expect(mine.existsSync(), isFalse);
      expect(claim.banks, isEmpty);
    });

    test('a listing that failed claims nothing', () {
      bank(name, modified: afterBoot);
      final after = listIntelWeightBanks(dirs: [temp]);

      expect(IntelWeightBankClaim.newSince(null, after).banks, isEmpty);
      expect(IntelWeightBankClaim.newSince(after, null).banks, isEmpty);
      expect(File('${temp.path}/$name.$pid.owner').existsSync(), isFalse);
    });

    test('a directory that cannot be listed makes the listing null', () {
      expect(
        listIntelWeightBanks(dirs: [temp, Directory('${temp.path}/missing')]),
        isNull,
      );
    });
  });
}
