// Host tests for `embedding_worker.dart` — the generalized background-
// isolate worker that drives a runtime-agnostic [EmbeddingForwardPass] +
// [EmbeddingTokenizer] pair (embedder decoupling plan Task 5; Phase 2 D-T1/
// D-T2/D-T3 mask thread).
//
// Uses fake [EmbeddingForwardPass]/[EmbeddingTokenizer] implementations
// built exclusively via top-level factory tear-offs (as required by
// `ForwardPassDescriptor.factory`/`.tokenizerFactory`'s docs — the worker
// genuinely `Isolate.spawn`s, so the fakes must survive the same boundary
// the isolate test proves). A tiny synthetic SentencePiece tokenizer (built
// in-memory, no checked-in model asset) supplies real tokenization for the
// legacy Invariant I1 tests; the D-T3 mask-thread tests use a fixed-output
// fake tokenizer instead, since they need to control the exact
// mask/tokenTypeIds the worker forwards.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_edge_ai_embeddings/src/embedding_tokenizer.dart';
import 'package:flutter_edge_ai/core/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/core/embedding/embedding_worker.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart'
    show ActiveEmbedderParams;
import 'package:flutter_edge_ai/core/embedding/forward_pass.dart';
import 'package:flutter_edge_ai/core/embedding/tokenizer_adapter.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake forward pass: behavior selected by [_FakeMode] (encoded into the
/// otherwise-unused `modelPath` field of the descriptor — the only sendable
/// channel available before the isolate boundary).
///
/// `modelPath` is `<mode>` or `<mode>@<log file>`. With a log file the pass
/// appends one line per `load`/`run`/`close` call to it — the only way the
/// test, on the main isolate, can see what the pass did inside the worker.
/// The writes are synchronous, so a line is on disk before the call returns.
class _FakeForwardPass implements EmbeddingForwardPass {
  _FakeForwardPass(String modelPath)
    : _mode = _FakeMode.fromModelPath(modelPath),
      _logPath = modelPath.contains('@')
          ? modelPath.substring(modelPath.indexOf('@') + 1)
          : null;

  final _FakeMode _mode;
  final String? _logPath;

  void _log(String line) {
    final path = _logPath;
    if (path == null) return;
    File(path).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  /// The gated modes hold a call until the test creates this file — for a
  /// close test, after it has sent the close, so the close is already queued
  /// when the run returns. No timing: the order is fixed by the test, not by
  /// how fast a runner is. Every test that gates also opens the gate in a
  /// teardown, and the gate gives up by itself after [_gateDeadline], so a
  /// failed test never leaves a worker blocked for good.
  File get _release => File('$_logPath.release');

  static const _gateDeadline = Duration(seconds: 30);

  /// Blocks this isolate — no events, no microtasks — until released, the way
  /// a synchronous native call does.
  void _blockUntilReleased() {
    final deadline = DateTime.now().add(_gateDeadline);
    while (!_release.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('fake gate was never released');
      }
      sleep(const Duration(milliseconds: 5));
    }
  }

  Future<void> _waitUntilReleased() async {
    final deadline = DateTime.now().add(_gateDeadline);
    while (!_release.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('fake gate was never released');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  @override
  Future<void> load() async {
    _log('load');
    switch (_mode) {
      case _FakeMode.failLoad:
      case _FakeMode.failLoadThenBlockingClose:
      case _FakeMode.failLoadThenBlockingCloseThrows:
        throw StateError('fake forward pass refused to load');
      case _FakeMode.blockingLoad:
        _blockUntilReleased();
      case _FakeMode.dieWhenIdle:
        // Dies with nothing in flight: an uncaught error a moment after load,
        // which ends the isolate (errorsAreFatal) without a _CloseAck.
        Timer(const Duration(milliseconds: 100), () {
          throw StateError('fake worker died while idle');
        });
      default:
        break;
    }
  }

  @override
  Future<ForwardResult> run({
    required List<int> tokenIds,
    List<int>? attentionMask,
    List<int>? tokenTypeIds,
  }) async {
    _log('run');
    switch (_mode) {
      case _FakeMode.blockingUntilReleased:
        // A synchronous native call: this isolate's event loop is blocked for
        // the whole of it, so nothing — a close included — is delivered until
        // it returns. The case the old `await for` loop could not get out of.
        // It has to block synchronously: an async fake leaves the event loop
        // free, so it passes even when the pump forgets to yield.
        _blockUntilReleased();
        return const ForwardResult(values: [3.0, 4.0], shape: [1, 2]);
      case _FakeMode.asyncUntilReleased:
        await _waitUntilReleased();
        return const ForwardResult(values: [3.0, 4.0], shape: [1, 2]);
      case _FakeMode.uncaughtErrorOnRun:
        // An error nothing catches, as a pass's stray callback might throw: it
        // ends the isolate mid-request, without a reply or a _CloseAck.
        scheduleMicrotask(() => throw StateError('fake uncaught worker error'));
        return Completer<ForwardResult>().future;
      case _FakeMode.failLoad:
      case _FakeMode.failLoadThenBlockingClose:
      case _FakeMode.failLoadThenBlockingCloseThrows:
      case _FakeMode.blockingLoad:
      case _FakeMode.dimensionThrows:
      case _FakeMode.throwOnClose:
      case _FakeMode.dieWhenIdle:
        return const ForwardResult(values: [3.0, 4.0], shape: [1, 2]);
      case _FakeMode.echoTokenIds:
        return ForwardResult(
          values: [for (final t in tokenIds) t.toDouble()],
          shape: [1, tokenIds.length],
        );
      case _FakeMode.pooledFinalFixed:
        // norm(3,4) == 5 — the tripwire vector: if anything normalizes this,
        // it comes back as [0.6, 0.8] instead of [3.0, 4.0].
        return const ForwardResult(values: [3.0, 4.0], shape: [1, 2]);
      case _FakeMode.tokenLevelFixed:
        // seq=3, dim=2 hidden states; mean -> [1,1] -> L2 -> [1/√2, 1/√2].
        return const ForwardResult(
          values: [1, 0, 0, 1, 2, 2],
          shape: [1, 3, 2],
        );
      case _FakeMode.echoMaskAndTypeIds:
        // Encode tokenIds, then -1, then attentionMask (or [-2] if null),
        // then -1, then tokenTypeIds (or [-2] if null) — a deterministic way
        // to prove exactly what `run()` received without any cross-isolate
        // side channel (D-T3: mask/typeIds must actually arrive here).
        return ForwardResult(
          values: [
            for (final t in tokenIds) t.toDouble(),
            -1,
            if (attentionMask != null)
              for (final m in attentionMask) m.toDouble()
            else
              -2,
            -1,
            if (tokenTypeIds != null)
              for (final tt in tokenTypeIds) tt.toDouble()
            else
              -2,
          ],
          shape: [
            1,
            tokenIds.length +
                1 +
                (attentionMask?.length ?? 1) +
                1 +
                (tokenTypeIds?.length ?? 1),
          ],
        );
      case _FakeMode.tokenLevelMaskSensitive:
        // seq=3, dim=2. Row 2 is a padding row with values far from rows 0/1
        // so a masked mean (excluding row 2) and an unmasked mean (including
        // it) point in visibly different directions — the anti-regression
        // proof that the worker actually applies the mask instead of
        // silently pooling over padding.
        return const ForwardResult(
          values: [1, 0, 0, 1, 5, -5],
          shape: [1, 3, 2],
        );
      case _FakeMode.resultMaskOverridesRequestMask:
        // The pass ignores whatever mask the request carried and reports its
        // OWN effective mask (e.g. it un-padded internally) — the worker
        // must prefer THIS mask, not the request's, when finalizing.
        return const ForwardResult(
          values: [1, 0, 0, 1, 5, -5],
          shape: [1, 3, 2],
          attentionMask: [1, 1, 1], // all real — nothing excluded
        );
      case _FakeMode.contractOverridePooledFinal:
        // Fixed non-normalized vector; if the worker used the descriptor's
        // `tokenLevel` contract instead of this pass's `pooledFinal`
        // override, meanPoolAndNormalize would throw (wrong rank) or, if it
        // didn't, the L2-normalize tripwire below would catch it.
        return const ForwardResult(values: [3.0, 4.0], shape: [1, 2]);
      case _FakeMode.killMidRequest:
        // Simulate an unexpected native crash: the isolate dies while a
        // request is in flight, never sending a reply.
        Isolate.current.kill(priority: Isolate.immediate);
        // Unreachable in practice — kill() terminates before this returns —
        // but the switch must be exhaustive and total.
        return const ForwardResult(values: [], shape: [1, 0]);
    }
  }

  @override
  Future<void> close() async {
    if (_mode == _FakeMode.failLoadThenBlockingClose ||
        _mode == _FakeMode.failLoadThenBlockingCloseThrows) {
      // A native close that does not return until the test says so.
      _blockUntilReleased();
    }
    _log('close');
    if (_mode == _FakeMode.throwOnClose ||
        _mode == _FakeMode.failLoadThenBlockingCloseThrows) {
      throw StateError('fake forward pass failed to close');
    }
  }

  @override
  int get outputDimension {
    if (_mode == _FakeMode.dimensionThrows) {
      throw StateError('fake forward pass has no dimension');
    }
    return 2;
  }

  @override
  int? get inputSequenceLength => null;

  @override
  EmbeddingOutputContract? get outputContract =>
      _mode == _FakeMode.contractOverridePooledFinal
      ? EmbeddingOutputContract.pooledFinal
      : null;
}

enum _FakeMode {
  echoTokenIds,
  pooledFinalFixed,
  tokenLevelFixed,
  echoMaskAndTypeIds,
  tokenLevelMaskSensitive,
  resultMaskOverridesRequestMask,
  contractOverridePooledFinal,
  killMidRequest,
  blockingUntilReleased,
  asyncUntilReleased,
  uncaughtErrorOnRun,
  dieWhenIdle,
  failLoad,
  failLoadThenBlockingClose,
  failLoadThenBlockingCloseThrows,
  blockingLoad,
  dimensionThrows,
  throwOnClose;

  static _FakeMode fromModelPath(String modelPath) {
    final at = modelPath.indexOf('@');
    final name = at < 0 ? modelPath : modelPath.substring(0, at);
    return _FakeMode.values.firstWhere((m) => m.name == name);
  }
}

EmbeddingForwardPass _buildFake(String modelPath) =>
    _FakeForwardPass(modelPath);

/// Fixed-output fake tokenizer: ignores the input text entirely and always
/// returns the same [TokenizedInput] — used by the D-T3 mask-thread tests,
/// which need exact control over the mask/tokenTypeIds the worker forwards
/// (a real tokenizer's output is harder to predict token-for-token).
class _FixedMaskTokenizer implements EmbeddingTokenizer {
  const _FixedMaskTokenizer();

  @override
  TokenizedInput encode(String prefix, String text) => const TokenizedInput(
    ids: [10, 11, 12],
    attentionMask: [1, 1, 0],
    tokenTypeIds: [0, 0, 1],
  );
}

Future<EmbeddingTokenizer> _buildFixedMaskTokenizer(
  String tokenizerPath,
) async => const _FixedMaskTokenizer();

/// Fixed-output fake tokenizer whose mask length does NOT match the token
/// count it returns — used to prove a length mismatch fails loud instead of
/// silently pooling over misaligned data.
class _MismatchedMaskTokenizer implements EmbeddingTokenizer {
  const _MismatchedMaskTokenizer();

  @override
  TokenizedInput encode(String prefix, String text) =>
      const TokenizedInput(ids: [1, 2, 3], attentionMask: [1, 1]);
}

Future<EmbeddingTokenizer> _buildMismatchedMaskTokenizer(
  String tokenizerPath,
) async => const _MismatchedMaskTokenizer();

/// Builds a tiny, self-contained SentencePiece tokenizer (BPE, single-char
/// vocab covering exactly the alphabet the tests use) as a JSON file this
/// library's own `TokenizerJsonLoader` can read — avoids checking in a real
/// (multi-MB) `.model` binary just for this unit test. Normalizer flags are
/// all `false` so `normalize()` is the identity function and token-stream
/// assertions can be exact.
Future<String> _writeTinyTokenizer(Directory dir, String alphabet) async {
  final pieces = ['<unk>', '<s>', '</s>', '<pad>', ...alphabet.split('')];
  final types = [2, 3, 3, 3, ...List.filled(alphabet.length, 1)];
  final json = {
    'version': '1.0',
    'model_type': 'bpe',
    'vocab': {
      'pieces': pieces,
      'scores': List.filled(pieces.length, 0.0),
      'types': types,
    },
    'special_tokens': {
      'unk': {'id': 0, 'piece': '<unk>'},
      'bos': {'id': 1, 'piece': '<s>'},
      'eos': {'id': 2, 'piece': '</s>'},
      'pad': {'id': 3, 'piece': '<pad>'},
    },
    'normalizer': {
      'add_dummy_prefix': false,
      'remove_extra_whitespaces': false,
      'escape_whitespaces': false,
    },
    'config': {'add_bos_token': false, 'add_eos_token': false},
    'byte_fallback': false,
  };
  final file = File('${dir.path}/tiny_tokenizer.json');
  await file.writeAsString(jsonEncode(json));
  return file.path;
}

void main() {
  late Directory tmpDir;
  late String tokenizerPath;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('embedding_worker_test');
    tokenizerPath = await _writeTinyTokenizer(tmpDir, 'p:ab');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  group('EmbeddingWorker output-contract dispatch', () {
    test('pooledFinal copies ForwardResult.values verbatim — no normalization '
        '(Invariant I0 tripwire: [3,4] has norm 5, must NOT come back as '
        '[0.6, 0.8])', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.pooledFinalFixed.name,
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        final vector = await worker.embed('ab', prefix: '');
        expect(vector, [3.0, 4.0]);
      } finally {
        await worker.close();
      }
    });

    test('tokenLevel mean-pools + L2-normalizes', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.tokenLevelFixed.name,
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.tokenLevel,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        final vector = await worker.embed('ab', prefix: '');
        expect(vector.length, 2);
        final norm = (vector[0] * vector[0] + vector[1] * vector[1]);
        expect(norm, closeTo(1.0, 1e-9));
      } finally {
        await worker.close();
      }
    });

    test(
      'the forward pass\'s outputContract override beats the descriptor\'s '
      '(design D-T2): descriptor says tokenLevel, pass says pooledFinal — '
      'the fixed [3,4] vector must come back verbatim, un-normalized',
      () async {
        final worker = await EmbeddingWorker.spawn(
          descriptor: ForwardPassDescriptor(
            engineTag: 'Fake',
            modelPath: _FakeMode.contractOverridePooledFinal.name,
            factory: _buildFake,
            tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
            // Descriptor says tokenLevel — the pass's outputContract getter
            // must win instead.
            outputContract: EmbeddingOutputContract.tokenLevel,
            activeBackend: PreferredBackend.cpu,
          ),
          tokenizerPath: tokenizerPath,
        );
        try {
          final vector = await worker.embed('ab', prefix: '');
          expect(vector, [3.0, 4.0]);
        } finally {
          await worker.close();
        }
      },
    );
  });

  group('EmbeddingWorker mask/tokenTypeIds thread (design D-T3)', () {
    test('tokenizer-produced attentionMask and tokenTypeIds reach '
        'EmbeddingForwardPass.run()', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.echoMaskAndTypeIds.name,
          factory: _buildFake,
          tokenizerFactory: _buildFixedMaskTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        final echoed = await worker.embed('anything', prefix: '');
        final rounded = echoed.map((d) => d.round()).toList();
        // ids=[10,11,12], sep=-1, mask=[1,1,0], sep=-1, typeIds=[0,0,1].
        expect(rounded, [10, 11, 12, -1, 1, 1, 0, -1, 0, 0, 1]);
      } finally {
        await worker.close();
      }
    });

    test('tokenLevel finalize uses the attentionMask to exclude padding — '
        'masked and unmasked means of the same fixed hidden states must '
        'differ (the anti-regression proof padding never leaks into the '
        'mean)', () async {
      final maskedWorker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.tokenLevelMaskSensitive.name,
          factory: _buildFake,
          // mask=[1,1,0] excludes the padding row (index 2).
          tokenizerFactory: _buildFixedMaskTokenizer,
          outputContract: EmbeddingOutputContract.tokenLevel,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      final unmaskedWorker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.tokenLevelMaskSensitive.name,
          factory: _buildFake,
          // Gemma-style tokenizer: no mask at all -> every row counted.
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.tokenLevel,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        final masked = await maskedWorker.embed('ab', prefix: '');
        final unmasked = await unmaskedWorker.embed('ab', prefix: '');
        // Masked mean over rows [1,0],[0,1] -> direction (0.5,0.5).
        // Unmasked mean over rows [1,0],[0,1],[5,-5] -> direction (2,-1.33),
        // opposite sign on the second component — unmistakably different.
        expect(masked[1], greaterThan(0));
        expect(unmasked[1], lessThan(0));
      } finally {
        await maskedWorker.close();
        await unmaskedWorker.close();
      }
    });

    test('ForwardResult.attentionMask (the pass\'s effective mask) takes '
        'precedence over the request\'s attentionMask when both are '
        'present', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.resultMaskOverridesRequestMask.name,
          factory: _buildFake,
          // Sends mask=[1,1,0] in the request...
          tokenizerFactory: _buildFixedMaskTokenizer,
          outputContract: EmbeddingOutputContract.tokenLevel,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        // ...but the fake pass reports attentionMask:[1,1,1] on the result,
        // so ALL THREE rows (including the [5,-5] "padding" row) must be
        // counted — same sign as the unmasked case above.
        final vector = await worker.embed('ab', prefix: '');
        expect(vector[1], lessThan(0));
      } finally {
        await worker.close();
      }
    });

    test('a mask whose length does not match the returned sequence length '
        'fails loud instead of silently pooling misaligned data', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.tokenLevelFixed.name, // shape [1, 3, 2]
          factory: _buildFake,
          tokenizerFactory: _buildMismatchedMaskTokenizer, // mask length 2
          outputContract: EmbeddingOutputContract.tokenLevel,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        await expectLater(
          worker.embed('ab', prefix: ''),
          throwsA(isA<StateError>()),
        );
      } finally {
        await worker.close();
      }
    });
  });

  group('EmbeddingWorker tokenization (Invariant I1)', () {
    test('wraps prefix+text with [bosId=2, ...ids, eosId=1]', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.echoTokenIds.name,
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        // prefix 'p:' + text 'ab' -> chars p,:,a,b -> vocab ids 4,5,6,7
        // (unk=0, bos=1, eos=2, pad=3, then p,:,a,b in that order).
        final echoed = await worker.embed('ab', prefix: 'p:');
        final tokenIds = echoed.map((d) => d.round()).toList();
        expect(tokenIds, [2, 4, 5, 6, 7, 1]);
      } finally {
        await worker.close();
      }
    });
  });

  group('EmbeddingWorker lifecycle', () {
    test('loads once, serves concurrent requests correlated by id', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.echoTokenIds.name,
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      try {
        final results = await Future.wait([
          worker.embed('a', prefix: ''),
          worker.embed('b', prefix: ''),
          worker.embed('ab', prefix: ''),
        ]);
        // Each reply must correlate to its own request, not get swapped.
        expect(results[0], [2, 6, 1]); // 'a' -> id 6
        expect(results[1], [2, 7, 1]); // 'b' -> id 7
        expect(results[2], [2, 6, 7, 1]); // 'ab' -> ids 6,7
      } finally {
        await worker.close();
      }
    });

    test('close() acks and further embed() calls fail', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.echoTokenIds.name,
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      await worker.close();
      await worker.close(); // idempotent
      expect(worker.embed('a', prefix: ''), throwsA(isA<StateError>()));
    });

    test('an unexpected worker death fails in-flight requests instead of '
        'hanging them forever', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.killMidRequest.name,
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      final killer = worker.embed('a', prefix: '');
      final bystander = worker.embed('b', prefix: '');
      await expectLater(killer, throwsA(isA<StateError>()));
      await expectLater(bystander, throwsA(isA<StateError>()));
    });
  });

  // The old close() waited five seconds for an ack and then killed the
  // isolate. The worker served its port one `await for` turn at a time, so a
  // close queued behind a batch never got there in time — and a killed isolate
  // never ran `pass.close()`, leaving the native model resident for the life
  // of the process. These tests read the fake pass's own log, written inside
  // the worker, to see what actually ran there.
  group('EmbeddingWorker close never abandons the native model', () {
    File logFor(String name) => File('${tmpDir.path}/$name.log');

    List<String> linesOf(File log) =>
        log.existsSync() ? log.readAsLinesSync() : const <String>[];

    Future<void> waitForLine(File log, String line) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!linesOf(log).contains(line)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the worker never logged "$line"');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    ForwardPassDescriptor descriptorFor(_FakeMode mode, File log) =>
        ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: '${mode.name}@${log.path}',
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        );

    /// Settles [future] into its value or its error, so a request that fails
    /// before the test looks at it is never reported as unhandled.
    Future<Object?> outcomeOf(Future<List<double>> future) =>
        future.then<Object?>((v) => v, onError: (Object e) => e);

    final closedBeforeRun = isA<StateError>().having(
      (e) => e.message,
      'message',
      contains('closed before this request ran'),
    );

    /// Creates the file the gated modes wait for, letting the call they hold
    /// return.
    void release(File log) => File('${log.path}.release').createSync();

    /// A log whose gate is also opened in a teardown, so a test that fails
    /// before releasing it never leaves a worker blocked behind it.
    File gatedLog(String name) {
      final log = logFor(name);
      addTearDown(() => release(log));
      return log;
    }

    /// Polls [printed] until a line contains [text].
    Future<void> waitForPrint(List<String> printed, String text) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!printed.any((l) => l.contains(text))) {
        if (DateTime.now().isAfter(deadline)) {
          fail('nothing printed "$text"; got: ${printed.join('\n')}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    ZoneSpecification capturePrints(List<String> printed) => ZoneSpecification(
      print: (self, parent, zone, line) => printed.add(line),
    );

    // Blocking is the case that matters: a synchronous FFI call keeps the
    // close in the worker's message queue until it returns, so only a
    // blocking fake shows whether the pump yields before each request. Async
    // is the case where the listener sees the close while the call is running.
    for (final mode in [
      _FakeMode.blockingUntilReleased,
      _FakeMode.asyncUntilReleased,
    ]) {
      test('${mode.name}: close() lets the request in flight finish, fails '
          'every queued one, and closes the pass exactly once', () async {
        final log = gatedLog(mode.name);
        final worker = await EmbeddingWorker.spawn(
          descriptor: descriptorFor(mode, log),
          tokenizerPath: tokenizerPath,
        );

        final inFlight = outcomeOf(worker.embed('ab', prefix: ''));
        final queued = [
          for (var i = 0; i < 20; i++)
            outcomeOf(worker.embed('ab', prefix: '')),
        ];
        await waitForLine(log, 'run');

        // The close is sent synchronously inside close(), so it is in the
        // worker's queue before the run is released: the order is fixed here,
        // not by how fast this machine is.
        final closing = worker.close();
        release(log);
        await closing;

        // Read the moment close() returns, without polling. close() waits for
        // the worker's own teardown, so the line is already on disk — and a
        // worker that was killed never writes it at all.
        final lines = linesOf(log);
        expect(
          lines.where((l) => l == 'close'),
          hasLength(1),
          reason:
              'the forward pass must be closed, once, before close() '
              'returns',
        );
        expect(
          lines.where((l) => l == 'run'),
          hasLength(1),
          reason: 'nothing queued may start once a close has been asked for',
        );
        expect(await inFlight, [
          3.0,
          4.0,
        ], reason: 'the request in flight finishes and gets its vector');
        for (final outcome in await Future.wait(queued)) {
          expect(outcome, closedBeforeRun);
        }
      });
    }

    test('close() never gives up on the call in flight: held past 6 s, the '
        'native close still runs before close() returns', () async {
      // The old close() gave up after 5 s and killed the worker, which then
      // never closed its pass. Waiting is the whole fix, so pin it.
      final log = gatedLog('never_kill');
      final worker = await EmbeddingWorker.spawn(
        descriptor: descriptorFor(_FakeMode.blockingUntilReleased, log),
        tokenizerPath: tokenizerPath,
      );
      final inFlight = outcomeOf(worker.embed('ab', prefix: ''));
      await waitForLine(log, 'run');

      var returned = false;
      final closing = worker.close().whenComplete(() => returned = true);
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(returned, isFalse, reason: 'close() must still be waiting');
      expect(linesOf(log), isNot(contains('close')));

      release(log);
      await closing;
      expect(
        linesOf(log).where((l) => l == 'close'),
        hasLength(1),
        reason: 'the native close ran, and before close() returned',
      );
      expect(await inFlight, [3.0, 4.0]);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a second close() waits for the same teardown instead of returning '
        'early', () async {
      final log = gatedLog('concurrent_close');
      final worker = await EmbeddingWorker.spawn(
        descriptor: descriptorFor(_FakeMode.asyncUntilReleased, log),
        tokenizerPath: tokenizerPath,
      );
      final inFlight = outcomeOf(worker.embed('ab', prefix: ''));
      await waitForLine(log, 'run');

      final first = worker.close();
      final second = worker.close();
      release(log);
      await second;

      // Checked before the FIRST close is awaited: a second close() that
      // returned early would get here while the worker is still running,
      // with nothing closed yet.
      expect(
        linesOf(log).where((l) => l == 'close'),
        hasLength(1),
        reason: 'the second close() returned before the pass was closed',
      );
      await first;
      await worker.close();
      expect(linesOf(log).where((l) => l == 'close'), hasLength(1));
      expect(await inFlight, [3.0, 4.0]);
    });

    test('a worker that dies mid-request fails it with the reason, warns '
        'with engine and model, and close() afterwards returns', () async {
      final log = logFor('uncaught_error');
      final printed = <String>[];
      late EmbeddingWorker worker;
      await runZoned(
        () async {
          worker = await EmbeddingWorker.spawn(
            descriptor: descriptorFor(_FakeMode.uncaughtErrorOnRun, log),
            tokenizerPath: tokenizerPath,
          );
          final dying = outcomeOf(worker.embed('ab', prefix: ''));
          final reason = await worker.unexpectedExit.timeout(
            const Duration(seconds: 10),
          );
          expect(reason, contains('fake uncaught worker error'));
          expect(
            await dying,
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('exited unexpectedly'),
                contains('fake uncaught worker error'),
              ),
            ),
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains('Fake'),
          contains(log.path),
          contains('may not have been closed'),
          contains('fake uncaught worker error'),
        ),
      );
      await worker.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('close() hung on a worker that had died'),
      );
      await expectLater(
        worker.embed('ab', prefix: ''),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake uncaught worker error'),
          ),
        ),
        reason: 'later calls say why the worker is gone, not just that it is',
      );
    });

    test('close() after an unexpected death returns at once, and later calls '
        'say the worker died', () async {
      final worker = await EmbeddingWorker.spawn(
        descriptor: ForwardPassDescriptor(
          engineTag: 'Fake',
          modelPath: _FakeMode.killMidRequest.name,
          factory: _buildFake,
          tokenizerFactory: loadGemmaSentencePieceEmbeddingTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.cpu,
        ),
        tokenizerPath: tokenizerPath,
      );
      await expectLater(
        worker.embed('ab', prefix: ''),
        throwsA(isA<StateError>()),
      );

      await worker.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('close() hung on a worker that had died'),
      );
      await expectLater(
        worker.embed('ab', prefix: ''),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('exited unexpectedly'),
          ),
        ),
      );
    });

    test('embed() fails at once from the moment close() is called', () async {
      final log = logFor('embed_after_close');
      final worker = await EmbeddingWorker.spawn(
        descriptor: descriptorFor(_FakeMode.pooledFinalFixed, log),
        tokenizerPath: tokenizerPath,
      );

      final closing = worker.close();
      await expectLater(
        worker.embed('ab', prefix: ''),
        throwsA(isA<StateError>()),
        reason: 'refused while the teardown is still running',
      );
      await closing;
      await expectLater(
        worker.embed('ab', prefix: ''),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
      expect(
        linesOf(log).where((l) => l == 'run'),
        isEmpty,
        reason: 'a refused call never reaches the forward pass',
      );
    });

    test(
      'a load failure reports the error, then closes the forward pass',
      () async {
        final log = logFor('fail_load');
        await expectLater(
          EmbeddingWorker.spawn(
            descriptor: descriptorFor(_FakeMode.failLoad, log),
            tokenizerPath: tokenizerPath,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('fake forward pass refused to load'),
            ),
          ),
        );
        // The error is sent first, so the close is waited for, not assumed.
        await waitForLine(log, 'close');
        expect(linesOf(log), ['load', 'close']);
      },
    );

    test('a failed load fails spawn at once even while closing its pass '
        'blocks, and that close still runs', () async {
      // The caller may hold the embedder cache's lane; a native close that
      // never returns must not hold it as well.
      final log = gatedLog('fail_load_blocking_close');
      await expectLater(
        EmbeddingWorker.spawn(
          descriptor: descriptorFor(_FakeMode.failLoadThenBlockingClose, log),
          tokenizerPath: tokenizerPath,
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('spawn waited for the close of the pass'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake forward pass refused to load'),
          ),
        ),
      );
      expect(linesOf(log), ['load'], reason: 'the close is still blocked');

      release(log);
      await waitForLine(log, 'close');
      expect(linesOf(log), ['load', 'close']);
    });

    test('a close that fails after a failed load is reported with the engine, '
        'the model and the stack', () async {
      final log = gatedLog('fail_load_close_throws');
      final printed = <String>[];
      await runZoned(
        () => expectLater(
          EmbeddingWorker.spawn(
            descriptor: descriptorFor(
              _FakeMode.failLoadThenBlockingCloseThrows,
              log,
            ),
            tokenizerPath: tokenizerPath,
          ),
          throwsA(isA<StateError>()),
        ),
        zoneSpecification: capturePrints(printed),
      );

      release(log);
      await waitForPrint(printed, 'failed to close after its load failed');
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains('Fake'),
          contains(log.path),
          contains('fake forward pass failed to close'),
          contains('embedding_worker_test.dart'),
        ),
      );
    });

    test(
      'spawn says once that a load is taking long, and keeps waiting',
      () async {
        final log = gatedLog('slow_load');
        final printed = <String>[];
        late EmbeddingWorker worker;
        await runZoned(() async {
          final spawning = EmbeddingWorker.spawn(
            descriptor: descriptorFor(_FakeMode.blockingLoad, log),
            tokenizerPath: tokenizerPath,
            slowLoadNotice: const Duration(milliseconds: 200),
          );
          await waitForPrint(printed, 'has taken 200 ms');
          release(log);
          worker = await spawning;
        }, zoneSpecification: capturePrints(printed));

        final notices = printed.where((l) => l.contains('has taken'));
        expect(notices, hasLength(1), reason: 'once, not on a timer');
        expect(
          notices.single,
          allOf(
            contains('WARNING'),
            contains('Fake'),
            contains(log.path),
            contains('still inside a native call'),
          ),
        );
        await worker.close();
      },
    );

    test(
      'a pass that loads but cannot report its dimension is closed too',
      () async {
        final log = logFor('dimension_throws');
        await expectLater(
          EmbeddingWorker.spawn(
            descriptor: descriptorFor(_FakeMode.dimensionThrows, log),
            tokenizerPath: tokenizerPath,
          ),
          throwsA(isA<StateError>()),
        );
        await waitForLine(log, 'close');
        expect(linesOf(log), ['load', 'close']);
      },
    );

    test('a forward pass whose close throws still lets close() return, and '
        'the failure is reported', () async {
      final log = logFor('throw_on_close');
      final printed = <String>[];
      await runZoned(
        () async {
          final worker = await EmbeddingWorker.spawn(
            descriptor: descriptorFor(_FakeMode.throwOnClose, log),
            tokenizerPath: tokenizerPath,
          );
          await worker.close();
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(linesOf(log), ['load', 'close']);
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains('fake forward pass failed to close'),
          // Which model, so the warning can be acted on...
          contains('Fake'),
          contains(log.path),
          // ...and where: the stack of the throwing close, which used to stay
          // behind in the worker's debug-only log.
          contains('embedding_worker_test.dart'),
        ),
      );
    });

    test('CommonEmbeddingModel: a second close() waits for the teardown the '
        'first one started', () async {
      final log = gatedLog('model_second_close');
      final model = await CommonEmbeddingModel.create(
        descriptor: descriptorFor(_FakeMode.asyncUntilReleased, log),
        tokenizerPath: tokenizerPath,
      );
      final inFlight = outcomeOf(model.generateEmbedding('ab'));
      await waitForLine(log, 'run');

      final first = model.close();
      final second = model.close();
      release(log);
      await second;

      // Before the first close is awaited: a second close() that returned
      // early is how an app's own close let the cache build a replacement
      // while the old native model was still loaded.
      expect(
        linesOf(log).where((l) => l == 'close'),
        hasLength(1),
        reason: 'the second close() returned before the pass was closed',
      );
      await first;
      expect(await inFlight, [3.0, 4.0]);
    });

    test('a worker that dies while idle turns its model closed, fires its '
        'close listeners once, warns, and the cache evicts it', () async {
      final log = logFor('die_when_idle');
      final printed = <String>[];
      final cache = EmbedderCache();
      final params = ActiveEmbedderParams(
        modelPath: '/die.tflite',
        tokenizerPath: '/die.json',
      );
      var listenerCalls = 0;
      var onCloseCalls = 0;
      final died = Completer<void>();
      late CommonEmbeddingModel model;

      await runZoned(
        () async {
          model = await CommonEmbeddingModel.create(
            descriptor: descriptorFor(_FakeMode.dieWhenIdle, log),
            tokenizerPath: tokenizerPath,
            onClose: () => onCloseCalls++,
          );
          model.addCloseListener(() {
            listenerCalls++;
            if (!died.isCompleted) died.complete();
          });
          cache.record(model, params);
          expect(cache.model, same(model));
          await died.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('the dead worker never closed its model'),
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(model.isClosed, isTrue);
      expect(listenerCalls, 1);
      expect(onCloseCalls, 1);
      expect(
        cache.model,
        isNull,
        reason: 'a dead model must not be handed to the next caller',
      );
      expect(
        printed.join('\n'),
        allOf(
          contains('WARNING'),
          contains(log.path),
          contains('fake worker died while idle'),
        ),
      );
      expect(
        () => model.generateEmbedding('ab'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake worker died while idle'),
          ),
        ),
      );

      // The next caller builds, and is not held: there is nothing left to
      // wait for. Closing the dead model afterwards notifies nobody twice.
      expect(
        await cache
            .reuseOrInvalidate(params, label: 'after death')
            .timeout(const Duration(seconds: 5)),
        isNull,
      );
      // The guard, not the emptied listener list, is what keeps a close()
      // after a death from notifying again: onClose is not a list.
      await model.close();
      expect(listenerCalls, 1);
      expect(onCloseCalls, 1, reason: 'onClose ran for the death already');
    });

    test('CommonEmbeddingModel: a throwing onClose still fires the close '
        'listeners, and only the first close() reports it', () async {
      final log = logFor('throwing_on_close');
      var listenerCalls = 0;
      final model = await CommonEmbeddingModel.create(
        descriptor: descriptorFor(_FakeMode.pooledFinalFixed, log),
        tokenizerPath: tokenizerPath,
        onClose: () => throw StateError('onClose failed'),
      );
      model.addCloseListener(() => listenerCalls++);

      await expectLater(
        model.close(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('onClose failed'),
          ),
        ),
        reason: 'the first caller learns what went wrong',
      );
      expect(
        listenerCalls,
        1,
        reason:
            'the cache evicts on a listener; skipping it leaves a closed '
            'model cached',
      );
      expect(linesOf(log), contains('close'), reason: 'the worker was closed');

      // The model is closed; later callers are not handed that error forever.
      await model.close();
      await model.close();
    });
  });
}
