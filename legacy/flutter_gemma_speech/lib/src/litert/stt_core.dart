// Synchronous, isolate-agnostic native core for LiteRT speech-to-text.
//
// Owns the LiteRT C API handles (environment, model, options, compiled
// model) and the HF tokenizer. `transcribe()` runs the blocking encode +
// autoregressive decode forward passes synchronously on the calling thread —
// it is meant to be driven from a background isolate (see `stt_worker.dart`)
// so the UI isolate stays free, mirroring `litert_embedding_core.dart`
// (#299).
//
// Generic over [SttModelProfile] — NOT model-specific. `seq2seq` decode is
// implemented for the `rawPcm` (moonshine-tiny) and `logMel` (whisper) input
// types; `ctc` decode is implemented for the `logMel`+`frameFirst` (parakeet)
// path. The `transcribe`/`_encode` dispatch switches are exhaustive over the
// decode/input/axis enums, so a new family value is a COMPILE error until
// wired — no runtime capability guard needed. The `rawPcm`+`paddingOnly` path is a
// VERBATIM port of the verified recipe in
// `docs/superpowers/notes/stt-transcript-recipe.md`:
//   - mask convention C (padding-only additive mask: 0.0 if j<len else
//     -1e9, applied identically to every query row — NO causal triangle);
//   - decoder start token BOS=1;
//   - argmax taken at tensor row `len - 1` (the position just written);
//   - stop at EOS=2 or `profile.maxDecodeTokens`.
// Do NOT "improve" moonshine's mask into a causal triangle — the recipe
// found that degrades output; see the note's "What NOT to do". `load()`
// parses `tokenizer.json` once and resolves every profile's named special
// tokens (`SttTokenRef`) through `resolveSttSpecialTokens` before
// constructing the core — moonshine's tokens are fixed ids and resolve
// byte-identically regardless of tokenizer content.
//
// Buffer create/lock/write/run/read/unlock sequence mirrors
// `litert_embedding_core.dart`'s forward-pass pattern, generalized to the
// encoder→decoder pair of signatures moonshine-style seq2seq models use.
// Tensor shapes not fixed by [SttModelProfile] (encoder hidden dims, decode
// vocab size) are auto-detected from the compiled model's tensor layouts —
// this is what keeps the core generic instead of hardcoding moonshine's
// `[1,207,288]`/`32768`.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
// Public, native-only bindings library (not the package barrel): this file
// is native-only — never reached on web — so it always needs the real FFI
// bindings. See the equivalent comment in `litert_embedding_core.dart` for
// why this import (not the `if (dart.library.ffi)` barrel) is correct here.
import 'package:flutter_gemma_litertlm/litert_bindings.dart';

import '../model/stt_model_profile.dart';
import '../tokenizer/stt_special_tokens.dart'
    show ResolvedSuppression, SttSpecialTokenResolver;
import '../tokenizer/stt_tokenizer.dart' show SttTokenizer;
import 'litert_graph.dart' show acceleratorFor;
import 'log_mel_frontend.dart' show computeLogMelSpectrogram, computeNemoLogMel;
import 'mel_filter_assets.dart' show loadMelFilterAsset;

/// Decoder start token (`<s>`), verified working on the first try — see the
/// recipe's "Mask convention that worked" section.
const int sttDecodeBosId = 1;

/// End-of-sequence token (`</s>`) — stops the greedy decode loop.
const int sttDecodeEosId = 2;

/// Pad with zeros or trim [samples] to exactly [windowSamples], per the
/// verified recipe's fixed-window step (moonshine: the first 80000 samples
/// = 5.000 s @ 16 kHz; zero-padded if the clip is shorter).
Float32List padOrTrimToWindow(Float32List samples, int windowSamples) {
  if (samples.length == windowSamples) return samples;
  final windowed = Float32List(windowSamples);
  final n = samples.length < windowSamples ? samples.length : windowSamples;
  windowed.setRange(0, n, samples);
  return windowed;
}

/// Index of the largest value in [values]. Ties keep the first (lowest
/// index) match — a standard greedy argmax.
int argmax(Float32List values) {
  var bestIndex = 0;
  var bestValue = values[0];
  for (var i = 1; i < values.length; i++) {
    if (values[i] > bestValue) {
      bestValue = values[i];
      bestIndex = i;
    }
  }
  return bestIndex;
}

/// Whether the greedy decode loop should stop: [eosId] was just generated,
/// or [generatedLength] has reached [maxDecodeTokens]. Pure — mirrors the
/// verified recipe's stop condition without touching native state.
bool shouldStopDecoding(
  int lastGeneratedId,
  int generatedLength,
  int maxDecodeTokens, {
  required int eosId,
}) {
  return lastGeneratedId == eosId || generatedLength >= maxDecodeTokens;
}

/// Greedy CTC decode: argmax each of [numFrames] frames over [numClasses]
/// logits (row-major `[numFrames, numClasses]`), collapse consecutive
/// duplicate ids (standard CTC collapse -- a run of the same id, however
/// long, becomes one), then drop every occurrence of [blankId] from the
/// collapsed sequence. No beam search, no language model -- plain greedy,
/// per the verified recipe
/// (docs/superpowers/notes/parakeet-ctc-spike-findings.md "CTC greedy
/// decode (verified recipe)"). Pure -- no native calls.
List<int> ctcGreedyDecode(
  Float32List logits, {
  required int blankId,
  required int numFrames,
  required int numClasses,
}) {
  final perFrameIds = <int>[];
  for (var f = 0; f < numFrames; f++) {
    final row = logits.sublist(f * numClasses, (f + 1) * numClasses);
    final id = argmax(row);
    // A NaN ANYWHERE in the frame means the backend produced invalid output
    // (GPU/NPU accelerator failure, cf. #214). Scan the WHOLE frame, not just
    // the argmax winner: `argmax`'s `>` is NaN-blind, so a NaN away from the
    // true-max position is silently skipped (treated as -inf) and the frame
    // would be accepted with a real winner — checking only `row[id]` catches
    // ONLY the case where a NaN seeds `row[0]`. Fail loudly on any NaN so a
    // corrupted forward pass can't yield a plausible-but-wrong transcript.
    // (The 63x1025 scan per parakeet clip is negligible.)
    if (row.any((v) => v.isNaN)) {
      throw StateError(
        'STT CTC decode produced NaN logits at frame $f — the model backend '
        'returned invalid output; transcription aborted rather than silently '
        'returning a garbled result.',
      );
    }
    perFrameIds.add(id);
  }
  final collapsed = <int>[];
  for (var i = 0; i < perFrameIds.length; i++) {
    if (i == 0 || perFrameIds[i] != perFrameIds[i - 1]) {
      collapsed.add(perFrameIds[i]);
    }
  }
  collapsed.removeWhere((id) => id == blankId);
  return collapsed;
}

/// Write `decode_args_2`'s `[1,1,maxTokens,maxTokens]` mask into
/// [maskHost] (already the right length, `maxTokens*maxTokens`) per
/// [convention]. `paddingOnly` is moonshine's verified convention C
/// (docs/superpowers/notes/stt-transcript-recipe.md): every row is
/// identical, valid iff `j<len`. `causal` additionally requires `j<=r`.
void writeDecoderMask(
  Float32List maskHost, {
  required int maxTokens,
  required int len,
  required SttDecoderMaskConvention convention,
}) {
  for (var r = 0; r < maxTokens; r++) {
    final rowBase = r * maxTokens;
    for (var j = 0; j < maxTokens; j++) {
      final valid = switch (convention) {
        SttDecoderMaskConvention.paddingOnly => j < len,
        SttDecoderMaskConvention.causal => j <= r && j < len,
      };
      maskHost[rowBase + j] = valid ? 0.0 : -1e9;
    }
  }
}

/// Force [suppression]'s blocked ids to `-inf` in [logitsRow] (a per-step
/// COPY of the decode output's argmax row — mutating it does not touch the
/// native tensor buffer) before argmax is taken. `null` suppression is a
/// no-op (moonshine, unchanged). [step] is `0` on the first decode call
/// after the seed prompt (`len == decoderPromptIds.length`), incrementing
/// thereafter.
void applySuppression(
  Float32List logitsRow, {
  required int step,
  required ResolvedSuppression? suppression,
}) {
  if (suppression == null) return;
  for (var id = suppression.suppressAboveId + 1; id < logitsRow.length; id++) {
    logitsRow[id] = double.negativeInfinity;
  }
  if (step == 0) {
    for (final id in suppression.suppressAtStepZeroIds) {
      if (id < logitsRow.length) logitsRow[id] = double.negativeInfinity;
    }
  }
}

/// Build the decoder seed prompt for one transcription.
///
/// [language] `null` returns [defaultPromptIds] unchanged. Otherwise the id at
/// [languagePromptIndex] is replaced with [language]'s id — a COPY, so the
/// default is never mutated.
///
/// This is why the output language is a per-call knob: `SttCore._decodeLoop`
/// already copies the seed on every transcription, so retargeting it costs one
/// map lookup and never touches the loaded model. Pure — no native calls, no
/// I/O — so the substitution is unit-testable without a checkpoint on disk,
/// matching this file's other pure helpers.
///
/// Throws [ArgumentError] rather than falling back to [defaultPromptIds]: a
/// caller who asked for German and silently got English is the exact failure
/// this path exists to prevent (#500).
List<int> promptForLanguage(
  String? language, {
  required List<int> defaultPromptIds,
  required int? languagePromptIndex,
  required Map<String, int> languageIds,
}) {
  if (language == null) return defaultPromptIds;

  if (languagePromptIndex == null) {
    throw ArgumentError.value(
      language,
      'language',
      'this model has no decoder-prompt language token; only whisper '
          'profiles accept a language',
    );
  }

  final id = languageIds[language];
  if (id == null) {
    final known = languageIds.keys.toList()..sort();
    throw ArgumentError.value(
      language,
      'language',
      'not one of the ${known.length} language codes in this checkpoint\'s '
          'tokenizer'
          '${known.isEmpty ? '' : ' (e.g. ${known.take(6).join(', ')}…)'}',
    );
  }

  return List<int>.of(defaultPromptIds)..[languagePromptIndex] = id;
}

/// [SttCore.load]'s name→id resolution result: the decoder's seed prompt
/// ids, its stop token id, its (optional) resolved suppression, and the
/// checkpoint's language codes.
typedef SttResolvedTokens = ({
  List<int> decoderPromptIds,
  int? eosId,
  ResolvedSuppression? suppression,

  /// This checkpoint's `<|xx|>` codes → ids, kept so `transcribe(language:)`
  /// can retarget the prompt's language slot per call. Empty for a profile
  /// with no language slot, and for an `.en`-only checkpoint.
  Map<String, int> languageIds,
});

/// Resolve [profile]'s [SttTokenRef]s (`decoderPromptTokens`, `eosToken`,
/// `suppressTokens`) against [tokenizerJson] (an already-parsed
/// `tokenizer.json` document) via [SttSpecialTokenResolver]. Pure — no I/O,
/// no native calls — so `load()`'s name→id step is unit-testable directly.
/// Moonshine's refs are `SttTokenRef.id` (fixed) and resolve
/// byte-identically regardless of [tokenizerJson]'s content; whisper's are
/// `SttTokenRef.name` and resolve from `tokenizerJson`'s `model.vocab`/
/// `added_tokens`. An unresolvable name throws the [StateError]
/// `SttSpecialTokenResolver.resolve` raises, naming it — no silent fallback
/// (Global Constraints).
SttResolvedTokens resolveSttSpecialTokens(
  SttModelProfile profile,
  Map<String, dynamic> tokenizerJson,
) {
  final resolver = SttSpecialTokenResolver(tokenizerJson);
  return (
    decoderPromptIds: [
      for (final ref in profile.decoderPromptTokens) ref.resolve(resolver),
    ],
    eosId: profile.eosToken?.resolve(resolver),
    suppression: profile.suppressTokens?.resolve(resolver),
    // Only harvested for a profile that HAS a language slot: moonshine and
    // parakeet would carry a map nothing can ever read.
    languageIds: profile.languagePromptIndex == null
        ? const <String, int>{}
        : resolver.languageIds,
  );
}

/// The encoder's output tensor (`decode_args_0` for every decode step),
/// plus the auto-detected shape needed to describe it to LiteRT again.
class _EncoderOutput {
  _EncoderOutput(this.alloc, this.frames, this.dim);
  final AlignedAlloc alloc;
  final int frames;
  final int dim;
}

/// Synchronous native STT core. NOT safe to share across isolates — the FFI
/// handles it holds are owned by the isolate that called [load].
class SttCore {
  SttCore._({
    required this._bindings,
    required this._environment,
    required this._model,
    required this._options,
    required this._compiledModel,
    required this._tokenizer,
    required this._profile,
    this._melFilters,
    List<int>? decoderPromptIds,
    int? eosId,
    this._resolvedSuppression,
    Map<String, int>? languageIds,
  }) : _decoderPromptIds = decoderPromptIds ?? const [sttDecodeBosId],
       _eosId = eosId ?? sttDecodeEosId,
       _languageIds = languageIds ?? const <String, int>{};

  final LiteRtBindings _bindings;
  final LiteRtEnvironment _environment;
  final LiteRtModel _model;
  final LiteRtOptions _options;
  final LiteRtCompiledModel _compiledModel;
  final SttTokenizer _tokenizer;
  final SttModelProfile _profile;

  /// Bundled mel filterbank matrix (`loadMelFilterAsset`), non-null for
  /// `logMel` profiles (whisper). `null` for `rawPcm` (moonshine) profiles —
  /// `_encode` never reads it on that path. Loaded once in `load()` from
  /// `profile.melFilterAsset`.
  final Float32List? _melFilters;

  /// Resolved DEFAULT decoder seed sequence (moonshine: `[1]`; whisper: the 4
  /// transcription ids seeded with the profile's default language), resolved
  /// once in `load()` via `resolveSttSpecialTokens`. Defaults to moonshine's
  /// hardcoded single BOS so this compiles standalone; every real call site
  /// passes the resolved ids.
  ///
  /// Used verbatim unless [transcribe] is given a `language` — see
  /// [_promptFor].
  final List<int> _decoderPromptIds;

  /// This checkpoint's language codes → token ids (`'de' -> 50261`), empty for
  /// a profile with no language slot. Read only by [_promptFor].
  final Map<String, int> _languageIds;

  /// The seed prompt for one transcription — see [promptForLanguage].
  List<int> _promptFor(String? language) => promptForLanguage(
    language,
    defaultPromptIds: _decoderPromptIds,
    languagePromptIndex: _profile.languagePromptIndex,
    languageIds: _languageIds,
  );

  /// Resolved stop token id (moonshine: 2; whisper: resolved
  /// `<|endoftext|>`), resolved once in `load()`. Defaults to moonshine's
  /// hardcoded EOS.
  ///
  /// Read ONLY by the `seq2seq` `_decodeLoop`. A `ctc` profile (parakeet) has
  /// a null `eosToken`, so the `?? sttDecodeEosId` fallback in the constructor
  /// leaves this at moonshine's EOS=2 — inert, because `_ctcDecode` is a
  /// single pass and never reads `_eosId`. A FUTURE seq2seq family with a null
  /// `eosToken` would silently inherit EOS=2 here; such a family must set a
  /// real `eosToken` (the seq2seq stop condition depends on it).
  final int _eosId;

  /// Resolved logit suppression, applied every decode step before argmax.
  /// `null` = no suppression (moonshine, unchanged).
  final ResolvedSuppression? _resolvedSuppression;

  bool _disposed = false;

  /// Load a `.tflite` STT model + its HF tokenizer and compile the model for
  /// [backend]. Heavy — call once, from a background isolate.
  static Future<SttCore> load({
    required String modelPath,
    required String tokenizerPath,
    required SttModelProfile profile,
    PreferredBackend? backend,
  }) async {
    // No capability guard here: `transcribe`'s decodeType switch and
    // `_encode`'s inputType/melAxisOrder switches are exhaustive (no default
    // arm), so an unwired enum value is a compile error, not a runtime
    // surprise — a stronger guarantee than the vacuous `!= a && != b` checks
    // this replaced (both enums are now fully implemented).
    final bindings = LiteRtBindings.open();
    final tokenizerText = await File(tokenizerPath).readAsString();
    final tokenizerJson = jsonDecode(tokenizerText) as Map<String, dynamic>;
    final resolved = resolveSttSpecialTokens(profile, tokenizerJson);
    final tokenizer = SttTokenizer.forProfileKind(
      profile.tokenizerKind,
      tokenizerJson,
      eosId: resolved.eosId,
    );
    final melFilters = profile.melFilterAsset != null
        ? loadMelFilterAsset(profile.melFilterAsset!)
        : null;

    // Track native handles as they are created so a failure partway through
    // frees everything already allocated instead of leaking it — the LiteRT
    // native heap is process-global and is NOT reclaimed by the isolate
    // dying. Mirrors `EmbeddingCore.load`.
    LiteRtEnvironment? environment;
    LiteRtModel? model;
    LiteRtOptions? options;
    LiteRtCompiledModel? compiled;
    try {
      final envPtr = calloc<LiteRtEnvironment>();
      bindings
          .createEnvironment(0, nullptr, envPtr)
          .check('LiteRtCreateEnvironment');
      environment = envPtr.value;
      calloc.free(envPtr);

      final pathC = modelPath.toNativeUtf8();
      final modelPtr = calloc<LiteRtModel>();
      try {
        bindings
            .createModelFromFile(environment, pathC, modelPtr)
            .check('LiteRtCreateModelFromFile($modelPath)');
      } finally {
        calloc.free(pathC);
      }
      model = modelPtr.value;
      calloc.free(modelPtr);

      final optsPtr = calloc<LiteRtOptions>();
      bindings.createOptions(optsPtr).check('LiteRtCreateOptions');
      options = optsPtr.value;
      calloc.free(optsPtr);
      bindings
          .setOptionsHardwareAccelerators(options, acceleratorFor(backend))
          .check('LiteRtSetOptionsHardwareAccelerators');

      final compiledPtr = calloc<LiteRtCompiledModel>();
      bindings
          .createCompiledModel(environment, model, options, compiledPtr)
          .check('LiteRtCreateCompiledModel');
      compiled = compiledPtr.value;
      calloc.free(compiledPtr);

      gemmaLog('[SttCore] loaded: backend=$backend');

      return SttCore._(
        bindings: bindings,
        environment: environment,
        model: model,
        options: options,
        compiledModel: compiled,
        tokenizer: tokenizer,
        profile: profile,
        melFilters: melFilters,
        decoderPromptIds: resolved.decoderPromptIds,
        eosId: resolved.eosId,
        resolvedSuppression: resolved.suppression,
        languageIds: resolved.languageIds,
      );
    } catch (_) {
      if (compiled != null) bindings.destroyCompiledModel(compiled);
      if (options != null) bindings.destroyOptions(options);
      if (model != null) bindings.destroyModel(model);
      if (environment != null) bindings.destroyEnvironment(environment);
      rethrow;
    }
  }

  /// Transcribe one fixed window of audio: pad/trim to
  /// `profile.windowSamples`, run the encoder (signature 0), then the
  /// greedy autoregressive decode loop (signature 1) until EOS or
  /// `profile.maxDecodeTokens`, then detokenize.
  ///
  /// [language] overrides the profile's default decoder-prompt language for
  /// THIS call only (whisper). `null` uses the default the model was loaded
  /// with. Nothing is reloaded either way.
  String transcribe(Float32List samples, {String? language}) {
    if (_disposed) {
      throw StateError('SttCore is disposed');
    }
    // Resolved before the encoder runs: a bad language code should cost a map
    // lookup, not a full mel + encoder pass first.
    final prompt = _promptFor(language);
    final windowed = padOrTrimToWindow(samples, _profile.windowSamples);
    final hidden = _encode(windowed);
    try {
      final ids = switch (_profile.decodeType) {
        SttDecodeType.seq2seq => _decodeLoop(hidden, prompt),
        SttDecodeType.ctc => _ctcDecode(hidden),
      };
      return _tokenizer.decode(ids);
    } finally {
      calloc.free(hidden.alloc.raw);
    }
  }

  /// Run the encoder (signature index 0). `rawPcm` (moonshine): `f32[1,
  /// windowSamples]`, UNCHANGED — byte-exact. `logMel` (whisper): runs the
  /// log-mel frontend first and feeds `f32[1, nMels, melFrames]`.
  /// `frames`/`dim` (the encoder's OUTPUT layout) are still auto-detected
  /// from the compiled model.
  _EncoderOutput _encode(Float32List windowedPcm) {
    final Float32List encoderInput;
    final int inRank;
    final int inDim0;
    final int inDim1;
    switch (_profile.inputType) {
      case SttInputType.rawPcm:
        encoderInput = windowedPcm;
        inRank = 2;
        inDim0 = windowedPcm.length;
        inDim1 = 0;
      case SttInputType.logMel:
        switch (_profile.melAxisOrder!) {
          case SttMelAxisOrder.melFirst:
            // whisper: `[nMels, melFrames]`.
            encoderInput = computeLogMelSpectrogram(
              windowedPcm,
              nFft: _profile.nFft!,
              hopLength: _profile.hopLength!,
              nMels: _profile.nMels!,
              melFrames: _profile.melFrames!,
              melFilters: _melFilters!,
              normalization: _profile.melNormalization,
            );
            inDim0 = _profile.nMels!;
            inDim1 = _profile.melFrames!;
          case SttMelAxisOrder.frameFirst:
            // parakeet: `[melFrames, nMels]` -- NeMo's frontend, distinct
            // params (winLength, preemphasis, Slaney filterbank, natural
            // log + full-window per-feature z-score), see
            // computeNemoLogMel's doc comment.
            encoderInput = computeNemoLogMel(
              windowedPcm,
              nFft: _profile.nFft!,
              winLength: _profile.winLength!,
              hopLength: _profile.hopLength!,
              preemphasis: _profile.preemphasis!,
              nMels: _profile.nMels!,
              melFrames: _profile.melFrames!,
              melFilters: _melFilters!,
            );
            inDim0 = _profile.melFrames!;
            inDim1 = _profile.nMels!;
        }
        inRank = 3;
    }

    final outLayout = LiteRtLayoutView.calloc();
    int frames, dim;
    try {
      _bindings
          .getOutputTensorLayouts(
            _compiledModel,
            0,
            1,
            outLayout.pointer,
            false,
          )
          .check('LiteRtGetCompiledModelOutputTensorLayouts(encode)');
      if (outLayout.rank < 3) {
        throw StateError(
          'STT encoder output has rank=${outLayout.rank}, expected 3',
        );
      }
      frames = outLayout.dimension(1);
      dim = outLayout.dimension(2);
    } finally {
      outLayout.free();
    }

    final inType = LiteRtRankedTensorTypeView.calloc()
      ..elementType = kLiteRtElementTypeFloat32
      ..rank = inRank
      ..setDimension(0, 1);
    if (inRank == 2) {
      inType.setDimension(1, inDim0);
    } else {
      inType.setDimension(1, inDim0);
      inType.setDimension(2, inDim1);
    }
    final inAlloc = allocAligned(encoderInput.length * 4);
    final inBufPtr = calloc<LiteRtTensorBuffer>();
    var inBufCreated = false;

    final outType = LiteRtRankedTensorTypeView.calloc()
      ..elementType = kLiteRtElementTypeFloat32
      ..rank = 3
      ..setDimension(0, 1)
      ..setDimension(1, frames)
      ..setDimension(2, dim);
    final outAlloc = allocAligned(frames * dim * 4);
    final outBufPtr = calloc<LiteRtTensorBuffer>();
    var outBufCreated = false;
    // On success outAlloc.raw is intentionally kept alive (it backs
    // decode_args_0); on ANY throw before the return it must be freed here or
    // it leaks native heap permanently (~frames*dim*4 bytes per failed encode).
    var returning = false;

    try {
      final inHost = inAlloc.aligned.cast<Float>();
      for (var i = 0; i < encoderInput.length; i++) {
        inHost[i] = encoderInput[i];
      }

      _bindings
          .createTensorBufferFromHostMemory(
            inType.pointer,
            inAlloc.aligned.cast(),
            encoderInput.length * 4,
            nullptr,
            inBufPtr,
          )
          .check('CreateTensorBufferFromHostMemory(encode in)');
      inBufCreated = true;

      _bindings
          .createTensorBufferFromHostMemory(
            outType.pointer,
            outAlloc.aligned.cast(),
            frames * dim * 4,
            nullptr,
            outBufPtr,
          )
          .check('CreateTensorBufferFromHostMemory(encode out)');
      outBufCreated = true;

      _bindings
          .runCompiledModel(_compiledModel, 0, 1, inBufPtr, 1, outBufPtr)
          .check('LiteRtRunCompiledModel(encode)');

      // Lock(Read) triggers the device→host sync on GPU/NPU. Read the hidden
      // state THROUGH the locked pointer: on GPU/NPU the accelerator writes
      // into device memory and Lock(Read) exposes a host-accessible copy that
      // may NOT be outAlloc — copying from lockedPtr into outAlloc (which
      // backs decode_args_0) guarantees the hidden state is materialized.
      // On CPU lockedPtr is the same host memory (a no-op self-copy, skipped).
      // Without this the host buffer stays zero on GPU → decode runs on zeros
      // → silent empty transcript. Mirrors litert_embedding_core.dart.
      final lockedPtr = calloc<Pointer<Void>>();
      try {
        _bindings
            .lockTensorBuffer(
              outBufPtr.value,
              lockedPtr,
              kLiteRtTensorBufferLockModeRead,
            )
            .check('LiteRtLockTensorBuffer(encode out)');
        final locked = lockedPtr.value.cast<Float>();
        final dst = outAlloc.aligned.cast<Float>();
        if (locked.address != dst.address) {
          for (var i = 0; i < frames * dim; i++) {
            dst[i] = locked[i];
          }
        }
        _bindings
            .unlockTensorBuffer(outBufPtr.value)
            .check('LiteRtUnlockTensorBuffer(encode out)');
      } finally {
        calloc.free(lockedPtr);
      }

      returning = true;
      return _EncoderOutput(outAlloc, frames, dim);
    } finally {
      if (inBufCreated) _bindings.destroyTensorBuffer(inBufPtr.value);
      // Destroying the tensor buffer WRAPPER does not free outAlloc's raw
      // host memory — that memory is kept alive and reused as
      // decode_args_0's backing store (freed by the caller after decode).
      if (outBufCreated) _bindings.destroyTensorBuffer(outBufPtr.value);
      calloc.free(inBufPtr);
      calloc.free(outBufPtr);
      calloc.free(inAlloc.raw);
      if (!returning) calloc.free(outAlloc.raw);
      inType.free();
      outType.free();
    }
  }

  /// Greedy autoregressive decode (signature index 1). `decode_args_0`
  /// (the encoder hidden state) is created once from [hidden] and reused
  /// unchanged for every step; `decode_args_1` (token ids) and
  /// `decode_args_2` (mask) are rewritten and recreated fresh each step.
  List<int> _decodeLoop(_EncoderOutput hidden, List<int> promptIds) {
    final maxTokens = _profile.maxDecodeTokens;

    // Discover the decode output vocab size (dimension 2 of
    // f32[1, maxTokens, vocab]) — generic over the profile. Done BEFORE
    // creating the hidden TensorBuffer so a failure here leaks no native
    // handle (the buffer + its destroy-in-finally are set up only after this).
    final outLayout = LiteRtLayoutView.calloc();
    int vocabSize;
    try {
      _bindings
          .getOutputTensorLayouts(
            _compiledModel,
            1,
            1,
            outLayout.pointer,
            false,
          )
          .check('LiteRtGetCompiledModelOutputTensorLayouts(decode)');
      if (outLayout.rank < 3) {
        throw StateError(
          'STT decode output has rank=${outLayout.rank}, expected 3',
        );
      }
      vocabSize = outLayout.dimension(2);
    } finally {
      outLayout.free();
    }

    // decode_args_0: the encoder hidden state, wrapped once and reused every
    // step. Created after vocab discovery so it is always covered by the
    // try/finally below that destroys it.
    final hiddenType = LiteRtRankedTensorTypeView.calloc()
      ..elementType = kLiteRtElementTypeFloat32
      ..rank = 3
      ..setDimension(0, 1)
      ..setDimension(1, hidden.frames)
      ..setDimension(2, hidden.dim);
    final hiddenBufPtr = calloc<LiteRtTensorBuffer>();
    _bindings
        .createTensorBufferFromHostMemory(
          hiddenType.pointer,
          hidden.alloc.aligned.cast(),
          hidden.frames * hidden.dim * 4,
          nullptr,
          hiddenBufPtr,
        )
        .check('CreateTensorBufferFromHostMemory(decode hidden)');
    hiddenType.free();

    final tokensAlloc = allocAligned(maxTokens * 4);
    final maskAlloc = allocAligned(maxTokens * maxTokens * 4);
    final decodeOutAlloc = allocAligned(maxTokens * vocabSize * 4);

    try {
      final tokensHost = tokensAlloc.aligned.cast<Int32>();
      final maskHost = maskAlloc.aligned.cast<Float>().asTypedList(
        maxTokens * maxTokens,
      );

      final generated = List<int>.from(promptIds);
      while (true) {
        final len = generated.length;

        // decode_args_1: i32[1, maxTokens] — token ids so far, right-padded
        // with 0.
        for (var i = 0; i < maxTokens; i++) {
          tokensHost[i] = i < len ? generated[i] : 0;
        }

        // decode_args_2: f32[1,1,maxTokens,maxTokens] — mask convention per
        // `_profile.decoderMaskConvention` (moonshine: `paddingOnly`,
        // verified recipe convention C; whisper: `causal`, per the Phase 0
        // spike). Do not change moonshine's convention — see the recipe's
        // "What NOT to do".
        writeDecoderMask(
          maskHost,
          maxTokens: maxTokens,
          len: len,
          convention: _profile.decoderMaskConvention,
        );

        final tokType = LiteRtRankedTensorTypeView.calloc()
          ..elementType = kLiteRtElementTypeInt32
          ..rank = 2
          ..setDimension(0, 1)
          ..setDimension(1, maxTokens);
        final maskType = LiteRtRankedTensorTypeView.calloc()
          ..elementType = kLiteRtElementTypeFloat32
          ..rank = 4
          ..setDimension(0, 1)
          ..setDimension(1, 1)
          ..setDimension(2, maxTokens)
          ..setDimension(3, maxTokens);
        final outType = LiteRtRankedTensorTypeView.calloc()
          ..elementType = kLiteRtElementTypeFloat32
          ..rank = 3
          ..setDimension(0, 1)
          ..setDimension(1, maxTokens)
          ..setDimension(2, vocabSize);

        final tokBufPtr = calloc<LiteRtTensorBuffer>();
        final maskBufPtr = calloc<LiteRtTensorBuffer>();
        final outBufPtr = calloc<LiteRtTensorBuffer>();
        var tokCreated = false, maskCreated = false, outCreated = false;
        int bestId;
        var nanLogit = false;

        try {
          _bindings
              .createTensorBufferFromHostMemory(
                tokType.pointer,
                tokensAlloc.aligned.cast(),
                maxTokens * 4,
                nullptr,
                tokBufPtr,
              )
              .check('CreateTensorBufferFromHostMemory(decode tokens)');
          tokCreated = true;

          _bindings
              .createTensorBufferFromHostMemory(
                maskType.pointer,
                maskAlloc.aligned.cast(),
                maxTokens * maxTokens * 4,
                nullptr,
                maskBufPtr,
              )
              .check('CreateTensorBufferFromHostMemory(decode mask)');
          maskCreated = true;

          _bindings
              .createTensorBufferFromHostMemory(
                outType.pointer,
                decodeOutAlloc.aligned.cast(),
                maxTokens * vocabSize * 4,
                nullptr,
                outBufPtr,
              )
              .check('CreateTensorBufferFromHostMemory(decode out)');
          outCreated = true;

          // Exact input order: decode_args_0 (hidden), decode_args_1
          // (tokens), decode_args_2 (mask).
          final inputs = calloc<LiteRtTensorBuffer>(3);
          inputs[0] = hiddenBufPtr.value;
          inputs[1] = tokBufPtr.value;
          inputs[2] = maskBufPtr.value;
          try {
            _bindings
                .runCompiledModel(_compiledModel, 1, 3, inputs, 1, outBufPtr)
                .check('LiteRtRunCompiledModel(decode)');
          } finally {
            calloc.free(inputs);
          }

          final lockedPtr = calloc<Pointer<Void>>();
          try {
            _bindings
                .lockTensorBuffer(
                  outBufPtr.value,
                  lockedPtr,
                  kLiteRtTensorBufferLockModeRead,
                )
                .check('LiteRtLockTensorBuffer(decode out)');
            // Argmax is taken at tensor row `len - 1` (0-indexed) — the
            // position of the token that was just written into the padded
            // sequence, NOT row 0 and NOT the last row.
            final row = len - 1;
            final logits = lockedPtr.value.cast<Float>().asTypedList(
              maxTokens * vocabSize,
            );
            final rowLogits = logits.sublist(
              row * vocabSize,
              (row + 1) * vocabSize,
            );
            applySuppression(
              rowLogits,
              step: len - promptIds.length,
              suppression: _resolvedSuppression,
            );
            bestId = argmax(rowLogits);
            // A NaN top logit means the backend produced invalid output (e.g.
            // a GPU/accelerator failure, cf. #214). argmax then collapses to
            // id 0 (<unk>), which detokenizes to '' and would be returned as a
            // "successful" empty transcript indistinguishable from a silent
            // clip. Flag it here and fail loudly after cleanup instead.
            nanLogit = rowLogits[bestId].isNaN;
            _bindings
                .unlockTensorBuffer(outBufPtr.value)
                .check('LiteRtUnlockTensorBuffer(decode out)');
          } finally {
            calloc.free(lockedPtr);
          }
        } finally {
          if (tokCreated) _bindings.destroyTensorBuffer(tokBufPtr.value);
          if (maskCreated) _bindings.destroyTensorBuffer(maskBufPtr.value);
          if (outCreated) _bindings.destroyTensorBuffer(outBufPtr.value);
          calloc.free(tokBufPtr);
          calloc.free(maskBufPtr);
          calloc.free(outBufPtr);
          tokType.free();
          maskType.free();
          outType.free();
        }

        if (nanLogit) {
          throw StateError(
            'STT decode produced NaN logits at step $len — the model backend '
            'returned invalid output; transcription aborted rather than '
            'silently returning an empty result.',
          );
        }

        generated.add(bestId);
        if (shouldStopDecoding(
          bestId,
          generated.length,
          maxTokens,
          eosId: _eosId,
        )) {
          if (bestId != _eosId && generated.length >= maxTokens) {
            gemmaLog(
              '[SttCore] decode hit the $maxTokens-token cap without EOS — '
              'transcript may be truncated.',
            );
          }
          return generated;
        }
      }
    } finally {
      _bindings.destroyTensorBuffer(hiddenBufPtr.value);
      calloc.free(hiddenBufPtr);
      calloc.free(tokensAlloc.raw);
      calloc.free(maskAlloc.raw);
      calloc.free(decodeOutAlloc.raw);
    }
  }

  /// Single-pass greedy CTC decode (parakeet): the encoder's OWN output
  /// tensor IS the CTC logits (no decoder subgraph, no growing token
  /// sequence, no mask, no per-step loop). `hidden.frames`/`hidden.dim`
  /// (already auto-detected in `_encode` from the compiled model's output
  /// tensor layout, per the design spec's fix #4) ARE the CTC frame count
  /// (63) and class count (1025), read at runtime -- never hardcoded.
  List<int> _ctcDecode(_EncoderOutput hidden) {
    final logits = hidden.alloc.aligned.cast<Float>().asTypedList(
      hidden.frames * hidden.dim,
    );
    return ctcGreedyDecode(
      logits,
      blankId: _profile.blankId!,
      numFrames: hidden.frames,
      numClasses: hidden.dim,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.destroyCompiledModel(_compiledModel);
    _bindings.destroyOptions(_options);
    _bindings.destroyModel(_model);
    _bindings.destroyEnvironment(_environment);
  }
}
