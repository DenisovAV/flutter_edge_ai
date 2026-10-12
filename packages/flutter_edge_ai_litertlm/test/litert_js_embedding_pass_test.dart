// `LiteRtJsEmbeddingPass` (web, LiteRT.js bundle API v2) on the VM, over a
// fake bundle that keeps ONE page-global state the way `litert_embeddings.js`
// does. The real interop is the browser suites' (test/web/); here: the API
// handshake, what reaches the bundle (`taskType.prefix + text`, for all nine
// task types), the limit and dimension the bundle read from the model, typed
// overflow, and the page-wide order of loads and disposes across passes.

import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — the app-facing model over core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
// ignore: implementation_imports — the app-facing model over core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/embedding_host_web.dart'
    as inline;
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_js_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

/// The page-global state of the bundle, shared by every pass on the "page".
///
/// "Tokens" are one per character plus BOS and EOS, so a test can reason
/// about lengths without a tokenizer.
final class _FakePage implements LiteRtJsBundle {
  _FakePage({
    this.loadDelays = const [Duration.zero],
    this.maxInputTokens = 64,
    this.dimension = 4,
  });

  /// Per load, in order; the last one repeats.
  final List<Duration> loadDelays;

  /// What the bundle reads from the model's input shape.
  final int maxInputTokens;

  /// What the bundle reads from the model's output shape.
  final int dimension;

  /// `liteRtEmbeddingsApiVersion` on this page; null = a bundle that set none.
  @override
  int? apiVersion = 2;

  /// When set, the next load fails after fetching the tokenizer — as the
  /// bundle does when the model fails to compile, or compiles into a graph it
  /// refuses — with [loadError].
  bool failNextLoad = false;
  String loadError = 'Failed to load LiteRT model: compile failed';

  /// When true, `web/litert_embeddings.js` is not on the page: none of its
  /// window functions exist, so every call into them throws, as the real
  /// interop does (`loadLiteRtEmbeddings is not a function`).
  bool missing = false;

  @override
  bool get isPresent => !missing;

  /// Called as a load starts, while the bundle is reading its URLs.
  void Function()? onLoad;

  bool modelLoaded = false;
  bool tokenizerLoaded = false;
  final loads = <({String model, String tokenizer})>[];
  int disposes = 0;

  /// Every string that reached `embedLiteRtText`, in order.
  final prompts = <String>[];

  @override
  Future<({int dimension, int maxInputTokens})> load(
    String modelUrl,
    String tokenizerUrl,
    String wasmPath,
  ) async {
    if (missing) throw StateError('loadLiteRtEmbeddings is not a function');
    loads.add((model: modelUrl, tokenizer: tokenizerUrl));
    onLoad?.call();
    await Future<void>.delayed(
      loadDelays[(loads.length - 1).clamp(0, loadDelays.length - 1)],
    );
    tokenizerLoaded = true;
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError(loadError);
    }
    modelLoaded = true;
    return (dimension: dimension, maxInputTokens: maxInputTokens);
  }

  @override
  Future<LiteRtJsEmbedResult> embed(String prefixedText) async {
    if (!modelLoaded) throw StateError('page state was disposed');
    prompts.add(prefixedText);
    final ids = prefixedText.length + 2;
    if (ids > maxInputTokens) {
      return LiteRtJsTooLong(actualTokens: ids, maxInputTokens: maxInputTokens);
    }
    return LiteRtJsVector(List<double>.filled(dimension, 0.5));
  }

  @override
  Future<void> dispose() async {
    if (missing) throw StateError('cleanupLiteRtEmbeddings is not a function');
    disposes++;
    modelLoaded = false;
    tokenizerLoaded = false;
  }
}

/// What `resolveWebModelUrl` does: `opfs://x` becomes a `blob:` URL,
/// anything else is returned unchanged.
Future<String> _fakeResolve(String path) async => path.startsWith('opfs://')
    ? 'blob:resolved/${path.substring('opfs://'.length)}'
    : path;

LiteRtJsEmbeddingConfig _config(
  _FakePage page, {
  String modelPath = 'blob:model',
  String tokenizerPath = 'blob:tokenizer',
  List<String>? revoked,
  List<String>? resolved,
}) => LiteRtJsEmbeddingConfig(
  modelPath: modelPath,
  tokenizerPath: tokenizerPath,
  bundle: page,
  resolveUrl: (path) {
    resolved?.add(path);
    return _fakeResolve(path);
  },
  revokeUrl: (url) => revoked?.add(url),
);

LiteRtJsEmbeddingPass _pass(
  _FakePage page, {
  String modelPath = 'blob:model',
  String tokenizerPath = 'blob:tokenizer',
  List<String>? revoked,
}) => LiteRtJsEmbeddingPass(
  _config(
    page,
    modelPath: modelPath,
    tokenizerPath: tokenizerPath,
    revoked: revoked,
  ),
);

/// R5 §7's message, verbatim: what an app with a stale `web/` copy sees.
const _staleBundleMessage =
    'web/litert_embeddings.js is older than flutter_edge_ai_litertlm 1.13.0; '
    'copy packages/flutter_edge_ai_litertlm/web/litert_embeddings.js into '
    'your web/';

void main() {
  group('bundle API v2 handshake', () {
    for (final version in [null, 1]) {
      test('a page whose bundle announces ${version ?? 'no'} API version is '
          'refused by name before anything is resolved or loaded', () async {
        final page = _FakePage()..apiVersion = version;
        final resolved = <String>[];
        final pass = LiteRtJsEmbeddingPass(
          _config(
            page,
            modelPath: 'opfs://m.tflite',
            tokenizerPath: 'opfs://t.model',
            resolved: resolved,
          ),
        );

        await expectLater(
          pass.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'LiteRT.js')
                .having((e) => e.message, 'message', _staleBundleMessage),
          ),
        );
        expect(resolved, isEmpty, reason: 'no blob: URL made for nothing');
        expect(page.loads, isEmpty);
        await pass.close();
        expect(page.disposes, 0, reason: 'the page was never touched');
      });
    }

    test('a bundle NEWER than this package is refused too, and says so rather '
        'than call it older', () async {
      final page = _FakePage()..apiVersion = 3;
      await expectLater(
        _pass(page).load(),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT.js')
              .having(
                (e) => e.message,
                'message',
                allOf(contains('API v3'), contains('litert_embeddings.js')),
              ),
        ),
      );
      expect(page.loads, isEmpty);
    });
  });

  group('what reaches the bundle', () {
    test('every task type reaches embedLiteRtText as taskType.prefix + text, '
        'built by the one prefix function', () async {
      final page = _FakePage(maxInputTokens: 64);
      final pass = _pass(page);
      await pass.load();

      for (final type in TaskType.values) {
        await pass.embed(EmbeddingInput.text('q'), type);
      }

      expect(page.prompts, [for (final t in TaskType.values) '${t.prefix}q']);
      await pass.close();
    });

    test('empty and whitespace-only text are embedded, as native .tflite '
        'embeds them (the prefix, BOS and EOS)', () async {
      final page = _FakePage(maxInputTokens: 64);
      final pass = _pass(page);
      await pass.load();

      final empty = await pass.embed(
        EmbeddingInput.text(''),
        TaskType.retrievalQuery,
      );
      final blank = await pass.embed(EmbeddingInput.text('  '), TaskType.none);

      expect(empty, hasLength(4));
      expect(blank, hasLength(4));
      expect(page.prompts, [TaskType.retrievalQuery.prefix, '  ']);
      await pass.close();
    });
  });

  group('limit, dimension and overflow come from the model', () {
    test('load reports the dimension and maxInputTokens the bundle read from '
        'the model — no constant 768, no null limit', () async {
      final info = await _pass(
        _FakePage(maxInputTokens: 256, dimension: 768),
      ).load();
      expect(info.dimension, 768);
      expect(info.maxInputTokens, 256);
      expect(info.modalities, {EmbeddingModality.text});
    });

    test('too_long becomes EmbeddingInputTooLongException with both counts; '
        'nothing is truncated and the pass keeps serving', () async {
      final page = _FakePage(maxInputTokens: 8);
      final pass = _pass(page);
      await pass.load();

      // TaskType.none adds no prefix: 6 characters + BOS + EOS = 8 ids fit.
      expect(
        await pass.embed(EmbeddingInput.text('abcdef'), TaskType.none),
        hasLength(4),
      );
      await expectLater(
        pass.embed(EmbeddingInput.text('abcdefg'), TaskType.none),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 8)
              .having((e) => e.actualTokens, 'actualTokens', 9),
        ),
      );
      expect(
        await pass.embed(EmbeddingInput.text('ab'), TaskType.none),
        hasLength(4),
        reason: 'an overflow does not break the pass',
      );
      await pass.close();
    });

    test('through core\'s inline host, the model an app gets reports the '
        'limit and throws the typed overflow (EG1 seq256 numbers)', () async {
      final page = _FakePage(maxInputTokens: 256, dimension: 768);
      final host = await inline.startEmbeddingHost(
        EmbeddingPassDescriptor<LiteRtJsEmbeddingConfig>(
          engineTag: liteRtJsEngine,
          factory: buildLiteRtJsEmbeddingPass,
          config: _config(page),
          activeBackend: null,
        ),
        declaredMedia: const {},
        label: 'embeddinggemma-300M_seq256_mixed-precision.tflite',
      );
      final model = CommonEmbeddingModel.withHost(host, engine: liteRtJsEngine);
      try {
        expect(model.maxInputTokens, 256);
        expect(model.dimension, 768);
        // retrievalDocument's prefix is 20 characters: 20 + 300 + 2 = 322.
        await expectLater(
          model.embed(
            EmbeddingInput.text('x' * 300),
            taskType: TaskType.retrievalDocument,
          ),
          throwsA(
            isA<EmbeddingInputTooLongException>()
                .having((e) => e.maxInputTokens, 'maxInputTokens', 256)
                .having((e) => e.actualTokens, 'actualTokens', 322),
          ),
        );
        expect(
          await model.embed(
            EmbeddingInput.text('short'),
            taskType: TaskType.retrievalQuery,
          ),
          hasLength(768),
        );
      } finally {
        await model.close();
      }
    });
  });

  group('a graph the bundle cannot feed', () {
    test('a multi-input (BERT-style) graph, which the bundle refuses at load, '
        'reaches the app as EmbeddingLoadException naming the reason, and '
        'the page is cleaned behind it', () async {
      // What litert_embeddings.js rejects loadLiteRtEmbeddings with for a
      // graph with three inputs; tool/web_build/test/api_v2.test.mjs pins it.
      const refusal =
          'Failed to initialize LiteRT embeddings: Failed to load LiteRT '
          'model: the model declares 3 inputs (input_ids, attention_mask, '
          'token_type_ids) but LiteRT.js embeddings feed exactly one: the '
          'token ids.';
      final page = _FakePage()
        ..failNextLoad = true
        ..loadError = refusal;
      Future<void>? cleanup;
      await expectLater(
        inline.startEmbeddingHost(
          EmbeddingPassDescriptor<LiteRtJsEmbeddingConfig>(
            engineTag: liteRtJsEngine,
            factory: buildLiteRtJsEmbeddingPass,
            config: _config(page),
            activeBackend: null,
          ),
          declaredMedia: const {},
          label: 'minilm.tflite',
          onFailedLoadCleanup: (done) => cleanup = done,
        ),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', liteRtJsEngine)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('declares 3 inputs'),
                  contains('exactly one: the token ids'),
                ),
              ),
        ),
      );
      await cleanup;
      // The bundle loaded the tokenizer before it refused the model.
      expect(page.disposes, 1);
      expect(page.tokenizerLoaded, isFalse);
    });
  });

  group('opfs:// paths (WebStorageMode.streaming)', () {
    test('the bundle gets RESOLVED URLs for the model and the tokenizer, never '
        'an opfs:// path its fetch() would reject', () async {
      final page = _FakePage();
      final pass = _pass(
        page,
        modelPath: 'opfs://gemma.tflite',
        tokenizerPath: 'opfs://sentencepiece.model',
      );

      await pass.load();

      expect(page.loads.single, (
        model: 'blob:resolved/gemma.tflite',
        tokenizer: 'blob:resolved/sentencepiece.model',
      ));
      await pass.close();
    });

    test(
      'a URL that needs no resolving reaches the bundle unchanged',
      () async {
        final page = _FakePage();
        final pass = _pass(page);
        await pass.load();
        expect(page.loads.single, (
          model: 'blob:model',
          tokenizer: 'blob:tokenizer',
        ));
        await pass.close();
      },
    );
  });

  group('object URLs the pass created', () {
    test('the blob: URLs made for opfs:// paths are revoked once the bundle '
        'has read them — not before — and embedding works after', () async {
      final revoked = <String>[];
      final page = _FakePage()
        ..onLoad = () => expect(revoked, isEmpty, reason: 'still being read');
      final pass = _pass(
        page,
        modelPath: 'opfs://gemma.tflite',
        tokenizerPath: 'opfs://sentencepiece.model',
        revoked: revoked,
      );

      await pass.load();

      expect(
        revoked,
        unorderedEquals([
          'blob:resolved/gemma.tflite',
          'blob:resolved/sentencepiece.model',
        ]),
      );
      expect(
        await pass.embed(EmbeddingInput.text('q'), TaskType.retrievalQuery),
        hasLength(4),
      );
      await pass.close();
    });

    test('a load that fails still releases both', () async {
      final revoked = <String>[];
      final page = _FakePage()..failNextLoad = true;
      final pass = _pass(
        page,
        modelPath: 'opfs://gemma.tflite',
        tokenizerPath: 'opfs://sentencepiece.model',
        revoked: revoked,
      );

      await expectLater(pass.load(), throwsStateError);
      expect(revoked, hasLength(2));
      await pass.close();
    });

    test('a URL core owns (not opfs://) is never revoked', () async {
      final revoked = <String>[];
      final pass = _pass(_FakePage(), revoked: revoked);
      await pass.load();
      await pass.close();
      expect(revoked, isEmpty);
    });
  });

  group('the page lane', () {
    test('a pass closing while its replacement loads leaves the replacement '
        'its page state', () async {
      // The old pass's load is the SLOW one and its close is queued behind it;
      // the replacement's load is fast. Without the lane the replacement
      // loaded first and the old dispose then deleted its state.
      final page = _FakePage(
        loadDelays: const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 10),
        ],
      );
      final a = _pass(page);
      final aLoad = a.load();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final aClose = a.close();
      final b = _pass(page);
      final bLoad = b.load();

      await aLoad;
      await aClose;
      await bLoad;

      expect(
        await b.embed(EmbeddingInput.text('z'), TaskType.retrievalQuery),
        hasLength(4),
        reason: 'the replacement lost its page state to the old close',
      );
      expect(page.disposes, 1);
      await b.close();
    });

    test('a failed load leaves nothing on the page: close disposes the '
        'tokenizer the bundle loaded before the model failed', () async {
      // The bundle loads the tokenizer, then compiles the model; when the
      // compile fails the tokenizer stays allocated, and the next load
      // overwrote it without freeing it — a leaked SentencePiece processor.
      final page = _FakePage()..failNextLoad = true;
      final failed = _pass(page);
      await expectLater(failed.load(), throwsStateError);
      expect(page.tokenizerLoaded, isTrue, reason: 'what the bundle leaves');

      await failed.close();

      expect(page.disposes, 1);
      expect(page.tokenizerLoaded, isFalse);
    });

    test('a pass that never reached the bundle disposes nothing', () async {
      final page = _FakePage();
      await _pass(page).close();
      final unresolvable = LiteRtJsEmbeddingPass(
        LiteRtJsEmbeddingConfig(
          modelPath: 'opfs://m',
          tokenizerPath: 'opfs://t',
          bundle: page,
          resolveUrl: (_) => Future.error(StateError('no OPFS')),
          revokeUrl: (_) {},
        ),
      );
      await expectLater(unresolvable.load(), throwsStateError);
      await unresolvable.close();
      expect(page.disposes, 0);
    });

    test(
      'a page without web/litert_embeddings.js: the load names the '
      'missing file, nothing is resolved, and close has nothing to dispose',
      () async {
        // The pass used to mark the page touched before it knew the bundle was
        // there, so the close behind the failed load called the missing
        // cleanupLiteRtEmbeddings — and core then printed a second, false
        // warning that a native model "may still be resident".
        final page = _FakePage()..missing = true;
        final resolved = <String>[];
        final pass = LiteRtJsEmbeddingPass(
          _config(
            page,
            modelPath: 'opfs://m.tflite',
            tokenizerPath: 'opfs://t.model',
            resolved: resolved,
          ),
        );

        await expectLater(
          pass.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'LiteRT.js')
                .having(
                  (e) => e.message,
                  'message',
                  contains('litert_embeddings.js'),
                ),
          ),
        );
        expect(resolved, isEmpty, reason: 'no blob: URL made for nothing');
        await pass.close();
        expect(page.disposes, 0);
      },
    );

    test(
      'a failed load does not block the lane: the next pass loads',
      () async {
        final page = _FakePage()..failNextLoad = true;
        final failed = _pass(page);
        await expectLater(failed.load(), throwsStateError);
        await failed.close();

        final next = _pass(page);
        await next.load();
        expect(page.loads, hasLength(2));
        await next.close();
      },
    );
  });
}
