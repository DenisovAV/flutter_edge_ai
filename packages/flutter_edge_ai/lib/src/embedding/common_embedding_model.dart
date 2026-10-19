// The one EmbeddingModel core builds (R5 D1, §4.2-4.3): a platform-neutral
// facade over an EmbeddingHost — the worker isolate on native, the inline host
// on web, picked by the conditional import below. Every request is validated
// here, on the caller's isolate, before anything is sent; media requests are
// admitted through two model-wide permits; embedAll keeps at most two of its
// requests outstanding; every reply is checked against the model's dimension.
// Not exported: apps receive it as an EmbeddingModel.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart'
    show CancelToken;
import 'package:meta/meta.dart' show visibleForTesting;

import 'embedding_exceptions.dart';
import 'embedding_host.dart';
import 'embedding_host_io.dart'
    if (dart.library.js_interop) 'embedding_host_web.dart'
    as host;
import 'embedding_input.dart';
import 'embedding_modality.dart';
import 'embedding_model.dart';
import 'embedding_pass.dart';
import 'task_type.dart';

/// How many media requests may be outstanding on one model, across every
/// caller: a `Future.wait` over a photo library must not queue a thousand
/// decoded-image-sized messages at the worker.
const _mediaPermits = 2;

/// How many of one `embedAll` call's requests may be outstanding at once
/// (D16): enough to keep the worker busy, few enough that a cancel stops
/// almost everything.
const _embedAllWindow = 2;

/// One installed file of the spec a model runs: its install name and, where
/// core can read it, its size in bytes (null on web, where the bytes live in
/// the browser's storage and their size is not read).
typedef InstalledEmbedderFile = ({String name, int? bytes});

/// How a model core built is replaced once closed: the shell entry point it
/// was built through (`createEmbeddingModel`), asked again for what it was
/// built with. The embedder cache's own rule decides what that returns.
typedef EmbedderReplacement = Future<EmbeddingModel> Function();

/// The embedding model core hands out. See [EmbeddingModel] for the contract.
final class CommonEmbeddingModel extends EmbeddingModel with CloseNotifier {
  CommonEmbeddingModel._(
    this._host, {
    required this.activeBackend,
    required this._engine,
    required this._label,
    List<InstalledEmbedderFile>? installedFiles,
    this.replacement,
  }) : installedFiles = installedFiles == null
           ? null
           : List.unmodifiable(installedFiles) {
    // A host that dies on its own (a crashed worker) turns this model closed
    // and tells its listeners, so the embedder cache evicts it and the next
    // caller gets a fresh one — instead of this one, whose every call fails.
    unawaited(_host.unexpectedExit.then(_onHostDied));
  }

  /// Wraps a running [host]. For the facade's own tests.
  @visibleForTesting
  CommonEmbeddingModel.withHost(
    EmbeddingHost host, {
    PreferredBackend? activeBackend,
    String engine = 'Test',
    String label = 'test-model',
    List<InstalledEmbedderFile>? installedFiles,
    EmbedderReplacement? replacement,
  }) : this._(
         host,
         activeBackend: activeBackend,
         engine: engine,
         label: label,
         installedFiles: installedFiles,
         replacement: replacement,
       );

  /// Starts [descriptor]'s pass on this platform's host (§4.2 step 4) and
  /// returns the model once it is loaded and checked against
  /// [declaredMedia]. [label] — the model file — names it in messages.
  /// [installedFiles] are the installed files of the spec it runs — names,
  /// and sizes where known — which name its embedding space for deciders.
  /// [replacement] gets the model core serves in its place once it is
  /// closed; the loader sets it.
  ///
  /// Fails with `EmbeddingLoadException`. A pass whose load failed is closed
  /// behind the error; [onFailedLoadCleanup] gets a future that ends when it
  /// has (see `EmbedderCache.trackFailedLoadCleanup`).
  static Future<CommonEmbeddingModel> start(
    EmbeddingPassDescriptor<Object> descriptor, {
    required Set<EmbeddingModality> declaredMedia,
    required String label,
    List<InstalledEmbedderFile>? installedFiles,
    EmbedderReplacement? replacement,
    bool requireReportedBackend = false,
    void Function(Future<void> cleanup)? onFailedLoadCleanup,
  }) async {
    final running = await host.startEmbeddingHost(
      descriptor,
      declaredMedia: declaredMedia,
      label: label,
      onFailedLoadCleanup: onFailedLoadCleanup,
    );
    if (requireReportedBackend && running.info.activeBackend == null) {
      // A failed placement check follows the same asynchronous cleanup gate as
      // a failed load: fail this caller now, but never overlap the next model.
      final cleanup = Future<void>.sync(running.close).catchError((
        Object e,
        StackTrace st,
      ) {
        warnEmbeddingHost(
          '${descriptor.engineTag} failed to close after missing '
          'loaded accelerator information for $label: $e\n$st',
        );
      });
      onFailedLoadCleanup?.call(cleanup);
      unawaited(cleanup);
      throw EmbeddingLoadException(
        '${descriptor.engineTag} advertises GPU support but did not report '
        'EmbeddingPassInfo.activeBackend for $label.',
        engine: descriptor.engineTag,
      );
    }
    return CommonEmbeddingModel._(
      running,
      activeBackend: running.info.activeBackend ?? descriptor.activeBackend,
      engine: descriptor.engineTag,
      label: label,
      installedFiles: installedFiles,
      replacement: replacement,
    );
  }

  final EmbeddingHost _host;
  final String _engine;
  final String _label;

  @override
  final PreferredBackend? activeBackend;

  /// The installed files of the spec this model runs — model first, then its
  /// tokenizer — with their sizes in bytes where core read them at load, or
  /// null for a model built without one (tests). The embedding-space identity
  /// of the deciders created from it.
  final List<InstalledEmbedderFile>? installedFiles;

  /// Gets the embedder core serves in this one's place — through the shell
  /// entry point that built this one, asked for the backend and media it was
  /// built with — or null for a model built without a shell (tests). A
  /// decider created from this model calls it once this model is closed.
  final EmbedderReplacement? replacement;

  bool _isClosed = false;
  String? _deathReason;
  bool _closeNotified = false;

  /// What every [close] after the first one waits for: the end of the same
  /// teardown, without its outcome.
  Future<void>? _closeFuture;

  int _freePermits = _mediaPermits;
  final _permitWaiters = Queue<Completer<void>>();

  @override
  int get dimension => _host.info.dimension;

  @override
  Set<EmbeddingModality> get modalities => _host.modalities;

  @override
  int? get maxInputTokens => _host.info.maxInputTokens;

  /// What the engine reported as [EmbeddingPassInfo.visionTokensPerImage]:
  /// the decider keys image-fitted deciders by it.
  int? get visionTokensPerImage => _host.info.visionTokensPerImage;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) {
    final refused = _validate(input);
    if (refused != null) return Future.error(refused);
    return _send(input, taskType);
  }

  @override
  Future<List<List<double>>> embedAll(
    List<EmbeddingInput> inputs, {
    required TaskType taskType,
    CancelToken? cancelToken,
  }) {
    // Read once: the caller's list may change while the call runs, and an
    // input appended later would be neither validated nor counted.
    final batch = List<EmbeddingInput>.unmodifiable(inputs);
    // A closed model refuses the call itself, empty or not (§4.3 step 1).
    if (_isClosed) return Future.error(_closedError());
    // Every input is checked before the first one is sent, and a refusal
    // says which input it was.
    for (var i = 0; i < batch.length; i++) {
      final refused = _validate(batch[i]);
      if (refused != null) {
        return Future.error(_naming(refused, i, batch.length));
      }
    }
    if (cancelToken?.isCancelled ?? false) {
      return Future.error(const EmbeddingCancelledException());
    }
    if (batch.isEmpty) return Future.value(<List<double>>[]);
    return _embedWindowed(batch, taskType, cancelToken);
  }

  /// §4.3 steps 1-4, in that order. Null when [input] may be sent.
  EmbeddingException? _validate(EmbeddingInput input) {
    if (_isClosed) return _closedError();
    final loaded = modalities;
    for (final modality in input.modalities) {
      if (!loaded.contains(modality)) {
        return EmbeddingModalityNotLoadedException(
          switch (modality) {
            EmbeddingModality.text =>
              'This model has no text tower; it embeds ${_names(loaded)} '
                  'only.',
            EmbeddingModality.image =>
              'This model was loaded for ${_names(loaded)}; the input '
                  'carries an image. Declare images at load: '
                  'getActiveEmbedder(supportImage: true).',
            EmbeddingModality.audio =>
              'This model was loaded for ${_names(loaded)}; the input '
                  'carries audio. Declare audio at load: '
                  'getActiveEmbedder(supportAudio: true).',
          },
          modality: modality,
          loaded: loaded,
        );
      }
    }
    final info = _host.info;
    // D17: more than one PART — several modalities, or several images — is a
    // combined input, and only an engine that combines parts receives one.
    final parts =
        (input.text != null ? 1 : 0) +
        input.images.length +
        (input.audio != null ? 1 : 0);
    if (parts > 1 && !info.combinedInputs) {
      return UnsupportedEmbeddingCombinationException(
        input.modalities.length > 1
            ? '$_engine embeds one part per vector; the input carries '
                  '${_names(input.modalities)}.'
            : '$_engine embeds one part per vector; the input carries '
                  '${input.images.length} images.',
        requested: input.modalities,
      );
    }
    for (final image in input.images) {
      final refused = _checkFormat(
        image,
        EmbeddingModality.image,
        info.imageFormats,
      );
      if (refused != null) return refused;
    }
    final audio = input.audio;
    if (audio != null) {
      final refused = _checkFormat(
        audio,
        EmbeddingModality.audio,
        info.audioFormats,
      );
      if (refused != null) return refused;
    }
    return null;
  }

  /// [refused] with "Input [index] of [count]: " in front of its message.
  static EmbeddingException _naming(
    EmbeddingException refused,
    int index,
    int count,
  ) {
    final message = 'Input $index of $count: ${refused.message}';
    return switch (refused) {
      EmbeddingModalityNotLoadedException(:final modality, :final loaded) =>
        EmbeddingModalityNotLoadedException(
          message,
          modality: modality,
          loaded: loaded,
        ),
      UnsupportedEmbeddingCombinationException(:final requested) =>
        UnsupportedEmbeddingCombinationException(message, requested: requested),
      EmbeddingFormatNotSupportedException(
        :final modality,
        :final detected,
        :final accepted,
      ) =>
        EmbeddingFormatNotSupportedException(
          message,
          modality: modality,
          detected: detected,
          accepted: accepted,
        ),
      // _validate returns nothing else per input (closed is checked first).
      _ => refused,
    };
  }

  EmbeddingFormatNotSupportedException? _checkFormat(
    Uint8List bytes,
    EmbeddingModality modality,
    Set<EncodedMediaFormat> accepted,
  ) {
    final detected = sniffEncodedMediaFormat(bytes);
    if (detected != null && accepted.contains(detected)) return null;
    return EmbeddingFormatNotSupportedException(
      detected == null
          ? 'The ${modality.name} bytes match no known container; $_engine '
                'accepts ${_formatNames(accepted)}.'
          : '$_engine does not decode ${detected.name} ${modality.name}s; it '
                'accepts ${_formatNames(accepted)}.',
      modality: modality,
      detected: detected,
      accepted: accepted,
    );
  }

  /// Admission, the request, and the per-reply dimension check. [input] is
  /// already validated.
  ///
  /// [settled] is set for a request of an `embedAll` call: a media request may
  /// wait a while for a permit, and if its call was cancelled or failed
  /// meanwhile it gives the permit straight back and never reaches the host.
  Future<List<double>> _send(
    EmbeddingInput input,
    TaskType taskType, {
    bool Function()? settled,
  }) async {
    final media = isMediaRequest(input);
    if (media) await _acquirePermit();
    try {
      if (_isClosed) throw _closedError();
      if (settled != null && settled()) throw const _CallSettled();
      final vector = await _host.embed(input, taskType);
      if (vector.length != dimension) {
        throw EmbeddingEngineException(
          '$_engine returned a vector of length ${vector.length} for '
          '$_label; the model reported dimension $dimension.',
          engine: _engine,
        );
      }
      return vector;
    } finally {
      if (media) _releasePermit();
    }
  }

  Future<List<List<double>>> _embedWindowed(
    List<EmbeddingInput> inputs,
    TaskType taskType,
    CancelToken? cancelToken,
  ) {
    final result = Completer<List<List<double>>>();
    final vectors = List<List<double>?>.filled(inputs.length, null);
    var next = 0;
    var outstanding = 0;
    var finished = 0;

    // The CancelToken's listener may outlive this call by far (an app can
    // keep one token for its lifetime), so it holds only this link, which
    // the call clears the moment it settles.
    final link = cancelToken == null ? null : _CancelLink();

    void fail(Object error, [StackTrace? stack]) {
      if (result.isCompleted) return;
      link?.clear();
      result.completeError(error, stack);
    }

    void sendMore() {
      while (!result.isCompleted &&
          outstanding < _embedAllWindow &&
          next < inputs.length) {
        if (cancelToken?.isCancelled ?? false) {
          fail(const EmbeddingCancelledException());
          return;
        }
        final index = next++;
        outstanding++;
        // Once the call has failed or been cancelled, what is still
        // outstanding finishes in the host and is dropped here.
        _send(inputs[index], taskType, settled: () => result.isCompleted).then(
          (vector) {
            outstanding--;
            if (result.isCompleted) return;
            // Nothing here may throw past the call: an error escaping this
            // callback would be unobserved and leave the call pending.
            try {
              vectors[index] = vector;
              if (++finished == inputs.length) {
                link?.clear();
                result.complete([for (final v in vectors) v!]);
              } else {
                sendMore();
              }
            } catch (e, st) {
              fail(e, st);
            }
          },
          onError: (Object error, StackTrace stack) {
            outstanding--;
            fail(error, stack);
          },
        );
      }
    }

    if (cancelToken != null && link != null) {
      link.onCancel = () => fail(const EmbeddingCancelledException());
      _listenForCancel(cancelToken, link);
    }
    sendMore();
    return result.future;
  }

  Future<void> _acquirePermit() {
    if (_freePermits > 0) {
      _freePermits--;
      return Future.value();
    }
    final waiter = Completer<void>();
    _permitWaiters.add(waiter);
    return waiter.future;
  }

  void _releasePermit() {
    if (_permitWaiters.isNotEmpty) {
      // Handed straight to the next waiter: the count never rises in between,
      // so a newcomer cannot overtake the queue.
      _permitWaiters.removeFirst().complete();
    } else {
      _freePermits++;
    }
  }

  void _failPermitWaiters() {
    final error = _closedError();
    while (_permitWaiters.isNotEmpty) {
      _permitWaiters.removeFirst().completeError(error);
    }
  }

  EmbedderClosedException _closedError() {
    final reason = _deathReason;
    return reason == null
        ? const EmbedderClosedException()
        : EmbedderClosedException(
            'The embedding model is closed: its $_engine worker exited '
            'unexpectedly ($reason).',
          );
  }

  /// Every caller — the app, the cache joining a close the app started —
  /// gets the same teardown and returns only once it is done, which is what
  /// lets the embedder cache hold a rebuild until the old native model is
  /// gone. Only the first caller is handed a listener's throw.
  @override
  Future<void> close() {
    final teardown = _closeFuture;
    if (teardown != null) return teardown;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    _failPermitWaiters();
    // Listeners AFTER the host's teardown: a listener is app code, and one
    // that threw first would leave the host running with nobody able to close
    // it. The window meanwhile is covered by [isClosed], already true, which
    // the embedder cache checks on every read. Each step runs whatever the
    // other did; a failing host close reaches the caller, and a listener that
    // also throws is printed rather than swapped in for it.
    await runTeardown('closing the $_engine embedder for $_label', [
      _host.close,
      _notifyClosed,
    ]);
  }

  void _notifyClosed() {
    if (_closeNotified) return;
    _closeNotified = true;
    fireCloseListeners();
  }

  void _onHostDied(String reason) {
    _isClosed = true;
    _deathReason = reason;
    _failPermitWaiters();
    try {
      _notifyClosed();
    } catch (e, st) {
      // Nobody awaits this path, so a throwing listener would otherwise be an
      // unhandled error with no context.
      warnEmbeddingHost(
        'a close listener threw while the $_engine embedder for $_label, '
        'whose engine had stopped ($reason), was being closed: $e\n$st',
      );
    }
  }
}

/// What a `CancelToken`'s listener holds for one `embedAll` call: the call's
/// cancel action until the call settles, nothing after. A token kept for the
/// life of an app therefore retains nothing of the calls it was passed to.
final class _CancelLink {
  void Function()? _onCancel;

  /// The call's cancel action. Counted while held, so a test can see that a
  /// settled call left nothing behind in the token.
  set onCancel(void Function()? action) {
    if (_onCancel == null && action != null) _liveCancelLinks++;
    if (_onCancel != null && action == null) _liveCancelLinks--;
    _onCancel = action;
  }

  void fire() => _onCancel?.call();

  void clear() => onCancel = null;
}

int _liveCancelLinks = 0;

/// Registers [link] with [token]. Top-level on purpose: a closure created
/// inside `_embedWindowed` would share that function's context — which holds
/// the call's results — and the token would keep all of it alive. This one's
/// context holds the link alone.
void _listenForCancel(CancelToken token, _CancelLink link) {
  unawaited(token.whenCancelled.then((_) => link.fire()));
}

/// How many cancel links still hold an `embedAll` call's cancel action — zero
/// once every call with a `CancelToken` has settled. For tests.
@visibleForTesting
int debugLiveEmbedAllCancelLinks() => _liveCancelLinks;

/// Thrown by [CommonEmbeddingModel._send] for a request whose `embedAll` call
/// settled while the request waited for a permit. Nobody observes it: the
/// call has already completed.
final class _CallSettled implements Exception {
  const _CallSettled();
}

String _names(Set<EmbeddingModality> modalities) => [
  for (final m in EmbeddingModality.values)
    if (modalities.contains(m)) m.name,
].join(' and ');

String _formatNames(Set<EncodedMediaFormat> formats) => formats.isEmpty
    ? 'none'
    : (formats.map((f) => f.name).toList()..sort()).join(', ');
