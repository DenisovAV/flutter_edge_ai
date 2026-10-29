// The hosts this package runs on natively, named once (lib/src/native_hosts.dart),
// must be the hosts the build hook has an archive for.

import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/native_hosts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every native host has an archive in the hook, and only those', () {
    final hook = File('hook/build.dart').readAsStringSync();
    final archives = {
      for (final m in RegExp(r"'litertlm-(\w+)\.tar\.gz'").allMatches(hook))
        m.group(1)!,
    };
    final asAbi = {
      for (final archive in archives)
        if (archive != 'ios_sim_arm64') archive.replaceAll('x86_64', 'x64'),
    };
    expect(archives, contains('ios_sim_arm64'));
    expect(asAbi, liteRtLmNativeAbis);
  });

  test('the EmbeddingGemma 2 GPU hosts are native hosts', () {
    expect(liteRtLmNativeAbis, containsAll(liteRtLmEmbeddingGpuAbis));
    expect(
      liteRtLmEmbeddingGpuAbis.intersection(liteRtLmEmbeddingGpuRefusedAbis),
      isEmpty,
    );
  });
}
