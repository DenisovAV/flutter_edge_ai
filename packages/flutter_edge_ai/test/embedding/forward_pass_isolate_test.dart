// REAL isolate-boundary sendability test for `ForwardPassDescriptor`.
//
// This is the crux test for the ForwardPass seam design (hardened plan D3/D4):
// the descriptor carries a top-level factory *tear-off*, which must survive
// being sent through a SendPort into a genuinely separate `Isolate.spawn`'d
// isolate, so that isolate can build its own `EmbeddingForwardPass` instance
// locally (no FFI pointer/handle ever crosses the boundary — only this
// descriptor does).
//
// If Dart rejects sending the descriptor (or the factory tear-off inside it),
// that is a critical, design-changing finding — this test must NOT be faked
// around; a failure here means the seam as designed does not work.

import 'dart:isolate';

import 'package:flutter_edge_ai/core/embedding/forward_pass.dart';
import 'package:flutter_edge_ai/core/embedding/tokenizer_adapter.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal forward-pass fake, built exclusively via the top-level
/// [_buildIsolateFake] tear-off below — this class is only ever constructed
/// through that factory, never referenced directly by the sending isolate.
class _IsolateFakeForwardPass implements EmbeddingForwardPass {
  _IsolateFakeForwardPass(this.modelPath);

  final String modelPath;

  @override
  Future<void> load() async {}

  @override
  Future<ForwardResult> run({
    required List<int> tokenIds,
    List<int>? attentionMask,
    List<int>? tokenTypeIds,
  }) async {
    // Echo tokenIds (as doubles) back as the "embedding" so the test can
    // assert the request data made it into the isolate and the result made
    // it back out.
    return ForwardResult(
      values: [for (final t in tokenIds) t.toDouble()],
      shape: [1, tokenIds.length],
    );
  }

  @override
  Future<void> close() async {}

  @override
  int get outputDimension => 1;

  @override
  int? get inputSequenceLength => null;

  @override
  EmbeddingOutputContract? get outputContract => null;
}

/// Top-level factory tear-off. MUST be top-level/static (see
/// `forward_pass.dart`'s `EmbeddingForwardPassFactory` doc) — this is exactly
/// the value under test: does a reference to *this* declaration survive a
/// spawn boundary intact?
EmbeddingForwardPass _buildIsolateFake(String modelPath) =>
    _IsolateFakeForwardPass(modelPath);

/// Minimal tokenizer fake, built exclusively through the top-level
/// [_buildIsolateFakeTokenizer] tear-off below.
class _IsolateFakeTokenizer implements EmbeddingTokenizer {
  const _IsolateFakeTokenizer();

  @override
  TokenizedInput encode(String prefix, String text) =>
      TokenizedInput(ids: [prefix.length, text.length]);
}

/// Top-level [EmbeddingTokenizerFactory] tear-off. MUST be top-level/static
/// (see `tokenizer_adapter.dart`'s doc) — this is the D-T1 half of the
/// boundary proof: does `ForwardPassDescriptor.tokenizerFactory` survive
/// `Isolate.spawn` alongside `.factory`?
Future<EmbeddingTokenizer> _buildIsolateFakeTokenizer(
  String tokenizerPath,
) async => const _IsolateFakeTokenizer();

/// Top-level isolate entry point. Receives the [ForwardPassDescriptor] (plus
/// a reply [SendPort]) as the spawn message, builds the forward pass AND the
/// tokenizer INSIDE this isolate purely from `descriptor.factory(...)` /
/// `descriptor.tokenizerFactory(...)`, runs one forward pass, and sends the
/// result back.
void _isolateEntry(List<Object?> args) async {
  final descriptor = args[0]! as ForwardPassDescriptor;
  final replyTo = args[1]! as SendPort;

  final forwardPass = descriptor.factory(descriptor.modelPath);
  await forwardPass.load();
  final result = await forwardPass.run(tokenIds: const [7, 8, 9]);
  await forwardPass.close();

  final tokenizer = await descriptor.tokenizerFactory(
    '/tmp/fake-tokenizer.json',
  );
  final tokenized = tokenizer.encode('pre', 'text');

  replyTo.send(<Object?>[
    result.values,
    result.shape,
    descriptor.engineTag,
    descriptor.modelPath,
    tokenized.ids,
  ]);
}

void main() {
  test('ForwardPassDescriptor (top-level factory + tokenizerFactory '
      'tear-offs) round-trips through a real Isolate.spawn boundary', () async {
    final descriptor = ForwardPassDescriptor(
      engineTag: 'FakeEngine',
      modelPath: '/tmp/fake-model.onnx',
      factory: _buildIsolateFake,
      tokenizerFactory: _buildIsolateFakeTokenizer,
      outputContract: EmbeddingOutputContract.pooledFinal,
      activeBackend: PreferredBackend.cpu,
    );

    final receivePort = ReceivePort();
    await Isolate.spawn(_isolateEntry, [descriptor, receivePort.sendPort]);

    final response = await receivePort.first as List<Object?>;
    receivePort.close();

    final values = (response[0]! as List).cast<double>();
    final shape = (response[1]! as List).cast<int>();
    final engineTag = response[2]! as String;
    final modelPath = response[3]! as String;
    final tokenizedIds = (response[4]! as List).cast<int>();

    // Proves the request data (tokenIds baked into _isolateEntry) actually
    // ran inside the spawned isolate and the ForwardResult crossed back.
    expect(values, [7.0, 8.0, 9.0]);
    expect(shape, [1, 3]);
    // Proves the descriptor's plain fields crossed too.
    expect(engineTag, 'FakeEngine');
    expect(modelPath, '/tmp/fake-model.onnx');
    // Proves `descriptor.tokenizerFactory` (D-T1) survived the same spawn
    // boundary and built a working tokenizer inside the receiving isolate:
    // 'pre'.length=3, 'text'.length=4.
    expect(tokenizedIds, [3, 4]);
  });
}
