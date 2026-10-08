import 'dart:convert';

import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A NativeAssetsManifest.json in the shape flutter_tools writes (format
/// 1.0.0, assets keyed by ABI then by asset id).
String _manifest(Map<String, Iterable<String>> idsByAbi) => jsonEncode({
  'format-version': [1, 0, 0],
  'native-assets': {
    for (final e in idsByAbi.entries)
      e.key: {
        for (final id in e.value) id: ['absolute', id.split('/').last],
      },
  },
});

final _base = [nativeAssetId('LiteRtLm'), nativeAssetId('StreamProxy')];
final _stack = [for (final n in qualcommNpuLibs) nativeAssetId(n)];

Future<NpuStackCheck> _check(String text, {String abi = 'android_arm64'}) =>
    checkQualcommNpuStack(read: () async => text, abi: abi);

void main() {
  test('every library registered: bundled', () async {
    final r = await _check(
      _manifest({
        'android_arm64': [..._base, ..._stack],
      }),
    );
    expect(r.bundled, isTrue);
    expect(r.known, isTrue);
    expect(r.reason, isNull);
  });

  test('none registered: the opt-in reason with the pubspec snippet', () async {
    final r = await _check(_manifest({'android_arm64': _base}));
    expect(r.bundled, isFalse);
    expect(r.known, isTrue, reason: 'a definite no skips npu');
    expect(r.reason, qualcommNpuNotEnabledReason);
    expect(r.reason, contains('qualcomm_npu: true'));
    expect(r.reason, contains('workspace root'));
  });

  test('a partial stack names what is missing', () async {
    final r = await _check(
      _manifest({
        'android_arm64': [
          ..._base,
          ..._stack.where((id) => !id.endsWith('V79Skel')),
        ],
      }),
    );
    expect(r.bundled, isFalse);
    expect(r.reason, contains('libQnnHtpV79Skel.so'));
    expect(r.reason, isNot(contains('libQnnHtp.so,')));
  });

  test('the stack under another ABI does not count', () async {
    final r = await _check(
      _manifest({
        'android_x64': [..._base, ..._stack],
      }),
    );
    expect(r.bundled, isFalse);
    expect(r.reason, qualcommNpuNotEnabledReason);
  });

  test('an unreadable manifest is unknown, not "not enabled"', () async {
    // What rootBundle throws in a background isolate with no binding.
    final r = await checkQualcommNpuStack(
      read: () async =>
          throw StateError('Binding has not yet been initialized'),
      abi: 'android_arm64',
    );
    expect(r.bundled, isFalse);
    expect(r.known, isFalse, reason: 'the platform side decides instead');
    expect(r.reason, contains('could not be read'));
    expect(r.reason, isNot(contains('qualcomm_npu: true')));
  });

  test(
    'a manifest in an unknown shape is not reported as "not enabled"',
    () async {
      final r = await _check('[1, 2, 3]');
      expect(r.bundled, isFalse);
      expect(r.known, isFalse);
      expect(r.reason, contains('not in a format'));
    },
  );

  test('ids match what the hook registers', () {
    expect(
      nativeAssetId(qualcommDispatchLib),
      'package:flutter_edge_ai_litertlm/src/native/LiteRtDispatch_Qualcomm',
    );
    expect(qualcommNpuLibs, hasLength(11));
    expect(androidLibFileName('QnnHtp'), 'libQnnHtp.so');
  });
}
