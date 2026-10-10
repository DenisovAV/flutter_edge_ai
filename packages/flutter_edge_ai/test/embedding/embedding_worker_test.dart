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
import 'package:flutter_edge_ai/core/embedding/embedding_worker.dart';
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

  /// How long one slow `run()` takes. Long enough that the test has time to
  /// send a close while it runs; twenty of them queued are longer than the
  /// five seconds the old close waited before it killed the worker.
  static const slowRun = Duration(milliseconds: 800);

  void _log(String line) {
    final path = _logPath;
    if (path == null) return;
    File(path).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  @override
  Future<void> load() async {
    _log('load');
    if (_mode == _FakeMode.failLoad) {
      throw StateError('fake forward pass refused to load');
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
      case _FakeMode.blockingSlowRun:
        // A synchronous native call: this isolate's event loop is blocked for
        // the whole of it, so nothing — a close included — is delivered until
        // it returns. The case the old `await for` loop could not get out of.
        sleep(slowRun);
        return const ForwardResult(values: [3.0, 4.0], shape: [1, 2]);
      case _FakeMode.asyncSlowRun:
        await Future<void>.delayed(slowRun);
        return const ForwardResult(values: [3.0, 4.0], shape: [1, 2]);
      case _FakeMode.failLoad:
      case _FakeMode.dimensionThrows:
      case _FakeMode.throwOnClose:
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
    _log('close');
    if (_mode == _FakeMode.throwOnClose) {
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
  blockingSlowRun,
  asyncSlowRun,
  failLoad,
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

    // Blocking is the case that matters: a synchronous FFI call keeps the
    // close in the worker's message queue until it returns. Async is the case
    // where the listener sees the close while the call is still running.
    for (final mode in [_FakeMode.blockingSlowRun, _FakeMode.asyncSlowRun]) {
      test('${mode.name}: close() lets the request in flight finish, fails '
          'every queued one, closes the pass exactly once, and does not wait '
          'for the queue', () async {
        final log = logFor(mode.name);
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

        final stopwatch = Stopwatch()..start();
        await worker.close();
        stopwatch.stop();

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
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 4)),
          reason:
              'twenty queued 800 ms requests are 16 s of work; close waits '
              'for the one in flight, not for the queue',
        );
      });
    }

    test('concurrent close() calls share one teardown', () async {
      final log = logFor('concurrent_close');
      final worker = await EmbeddingWorker.spawn(
        descriptor: descriptorFor(_FakeMode.asyncSlowRun, log),
        tokenizerPath: tokenizerPath,
      );
      final inFlight = outcomeOf(worker.embed('ab', prefix: ''));
      await waitForLine(log, 'run');

      await Future.wait([worker.close(), worker.close()]);
      await worker.close();

      expect(linesOf(log).where((l) => l == 'close'), hasLength(1));
      expect(await inFlight, [3.0, 4.0]);
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

    test('a load failure closes the forward pass before the error reaches '
        'the caller', () async {
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
      // No polling: the worker closes the pass BEFORE it sends the error.
      expect(linesOf(log), ['load', 'close']);
    });

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
        ),
      );
    });
  });
}
