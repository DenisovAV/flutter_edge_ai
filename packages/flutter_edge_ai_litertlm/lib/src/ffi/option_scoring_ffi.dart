// The native calls behind InferenceModel.createDecider on LiteRT-LM: render a
// decision prompt, and score options as the model's reply through the session
// API. Both block for the whole native call (a prefill, one scoring pass per
// option), so they run on a spawned isolate, as the engine create does.
//
// Bound with `lookupFunction` against LiteRT-LM 0.18.0's own headers
// (`c/engine.h`, `c/conversation.h` at pin b2f686e2), not through
// `litert_lm_bindings.dart`: that file is generated from an older header, whose
// `litert_lm_session_run_prefill` takes an array of structs where 0.18.0 takes
// an array of pointers to `litert_lm_input_data_create` objects.
//
// What each step does mirrors litetune's ENGINE_SCRIPT
// (`decision_scripts.py`), the scorer the model's temperature and threshold
// were fitted with: a session with no prompt template and a greedy TOP_P
// sampler, the prompt prefilled, a checkpoint, the prompt's last token
// prefilled again in mode `once`, then each target scored and rewound.
//
// The decider SPI (OptionScoringRun) is @experimental.
// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';

import 'litert_lm_library.dart';

/// `kLiteRtLmSamplerTypeTopP`.
const _topP = 2;

/// `kLiteRtLmInputDataTypeText`.
const _text = 0;

/// The checkpoint each scoring pass rewinds to.
const _checkpoint = 'flutter_edge_ai_decision_prompt';

/// [content] as one user message, rendered by the model's chat template
/// through a throwaway conversation (`render_message_to_string`).
Future<String> renderUserMessageOffMainIsolate({
  required int engineAddr,
  required String content,
}) {
  final isolateLogLevel = edgeAiLogLevel;
  return Isolate.run(() {
    edgeAiLogLevel = isolateLogLevel;
    final n = _Native(openLiteRtLmLibrary());
    final sessionConfig = n.greedySessionConfig(applyPromptTemplate: null);
    n.sessionConfigSetMaxOutputTokens(sessionConfig, 1);
    final config = n.conversationConfigCreate();
    if (config == nullptr) {
      n.sessionConfigDelete(sessionConfig);
      throw StateError(n.failure('litert_lm_conversation_config_create'));
    }
    n.conversationConfigSetSessionConfig(config, sessionConfig);
    n.sessionConfigDelete(sessionConfig);
    final conversation = n.conversationCreate(
      Pointer.fromAddress(engineAddr),
      config,
    );
    n.conversationConfigDelete(config);
    if (conversation == nullptr) {
      throw StateError(n.failure('litert_lm_conversation_create'));
    }
    final message = jsonEncode({
      'role': 'user',
      'content': content,
    }).toNativeUtf8();
    try {
      final rendered = n.render(conversation, message);
      if (rendered == nullptr) {
        throw StateError(
          n.failure('litert_lm_conversation_render_message_to_string'),
        );
      }
      // Owned by the conversation: copied before it is deleted.
      return rendered.toDartString();
    } finally {
      malloc.free(message);
      n.conversationDelete(conversation);
    }
  });
}

/// Scores each of [targets] after [prompt] in one fresh session; see
/// `OptionScorer.score`.
Future<OptionScoringRun> scoreTargetsOffMainIsolate({
  required int engineAddr,
  required String prompt,
  required List<String> targets,
  String? reprefill,
}) {
  final isolateLogLevel = edgeAiLogLevel;
  return Isolate.run(() {
    edgeAiLogLevel = isolateLogLevel;
    final n = _Native(openLiteRtLmLibrary());
    final config = n.greedySessionConfig(applyPromptTemplate: false);
    final session = n.engineCreateSession(
      Pointer.fromAddress(engineAddr),
      config,
    );
    n.sessionConfigDelete(config);
    if (session == nullptr) {
      throw StateError(n.failure('litert_lm_engine_create_session'));
    }
    final label = _checkpoint.toNativeUtf8();
    try {
      final prefillWatch = Stopwatch()..start();
      n.prefill(session, prompt);
      if (targets.length > 1) {
        n.checked(
          n.saveCheckpoint(session, label),
          'litert_lm_session_save_checkpoint',
        );
      }
      // Once per decision, after the checkpoint: rewinding resets only the
      // step, and the cell this prefill wrote stays (litetune, measured
      // 2026-10-16).
      if (reprefill != null) n.prefill(session, reprefill);
      prefillWatch.stop();
      final scoreWatch = Stopwatch()..start();
      final scores = <List<double>>[];
      for (var i = 0; i < targets.length; i++) {
        scores.add(n.score(session, targets[i]));
        if (i < targets.length - 1) {
          n.checked(
            n.rewindToCheckpoint(session, label),
            'litert_lm_session_rewind_to_checkpoint',
          );
        }
      }
      return OptionScoringRun(
        tokenScores: scores,
        prefillTime: prefillWatch.elapsed,
        scoreTime: scoreWatch.elapsed,
      );
    } finally {
      malloc.free(label);
      n.sessionDelete(session);
    }
  });
}

typedef _Ptr = Pointer<Void>;

/// The C calls, looked up on the isolate that makes them.
final class _Native {
  _Native(this.lib)
    : sessionConfigCreate = lib
          .lookupFunction<_Ptr Function(), _Ptr Function()>(
            'litert_lm_session_config_create',
          ),
      sessionConfigDelete = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'litert_lm_session_config_delete',
          ),
      sessionConfigSetApplyPromptTemplate = lib
          .lookupFunction<Void Function(_Ptr, Bool), void Function(_Ptr, bool)>(
            'litert_lm_session_config_set_apply_prompt_template',
          ),
      sessionConfigSetMaxOutputTokens = lib
          .lookupFunction<Void Function(_Ptr, Int32), void Function(_Ptr, int)>(
            'litert_lm_session_config_set_max_output_tokens',
          ),
      sessionConfigSetSamplerParams = lib
          .lookupFunction<Void Function(_Ptr, _Ptr), void Function(_Ptr, _Ptr)>(
            'litert_lm_session_config_set_sampler_params',
          ),
      samplerParamsCreate = lib
          .lookupFunction<_Ptr Function(Int32), _Ptr Function(int)>(
            'litert_lm_sampler_params_create',
          ),
      samplerParamsDelete = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'litert_lm_sampler_params_delete',
          ),
      samplerParamsSetTopK = lib
          .lookupFunction<Void Function(_Ptr, Int32), void Function(_Ptr, int)>(
            'litert_lm_sampler_params_set_top_k',
          ),
      samplerParamsSetTopP = lib
          .lookupFunction<
            Void Function(_Ptr, Float),
            void Function(_Ptr, double)
          >('litert_lm_sampler_params_set_top_p'),
      samplerParamsSetTemperature = lib
          .lookupFunction<
            Void Function(_Ptr, Float),
            void Function(_Ptr, double)
          >('litert_lm_sampler_params_set_temperature'),
      samplerParamsSetSeed = lib
          .lookupFunction<Void Function(_Ptr, Int32), void Function(_Ptr, int)>(
            'litert_lm_sampler_params_set_seed',
          ),
      conversationConfigCreate = lib
          .lookupFunction<_Ptr Function(), _Ptr Function()>(
            'litert_lm_conversation_config_create',
          ),
      conversationConfigSetSessionConfig = lib
          .lookupFunction<Void Function(_Ptr, _Ptr), void Function(_Ptr, _Ptr)>(
            'litert_lm_conversation_config_set_session_config',
          ),
      conversationConfigDelete = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'litert_lm_conversation_config_delete',
          ),
      conversationCreate = lib
          .lookupFunction<_Ptr Function(_Ptr, _Ptr), _Ptr Function(_Ptr, _Ptr)>(
            'litert_lm_conversation_create',
          ),
      conversationDelete = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'litert_lm_conversation_delete',
          ),
      render = lib
          .lookupFunction<
            Pointer<Utf8> Function(_Ptr, Pointer<Utf8>),
            Pointer<Utf8> Function(_Ptr, Pointer<Utf8>)
          >('litert_lm_conversation_render_message_to_string'),
      engineCreateSession = lib
          .lookupFunction<_Ptr Function(_Ptr, _Ptr), _Ptr Function(_Ptr, _Ptr)>(
            'litert_lm_engine_create_session',
          ),
      sessionDelete = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'litert_lm_session_delete',
          ),
      inputDataCreate = lib
          .lookupFunction<
            _Ptr Function(Int32, _Ptr, Size),
            _Ptr Function(int, _Ptr, int)
          >('litert_lm_input_data_create'),
      inputDataDelete = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'litert_lm_input_data_delete',
          ),
      runPrefill = lib
          .lookupFunction<
            Int32 Function(_Ptr, Pointer<_Ptr>, Size),
            int Function(_Ptr, Pointer<_Ptr>, int)
          >('litert_lm_session_run_prefill'),
      saveCheckpoint = lib
          .lookupFunction<
            Int32 Function(_Ptr, Pointer<Utf8>),
            int Function(_Ptr, Pointer<Utf8>)
          >('litert_lm_session_save_checkpoint'),
      rewindToCheckpoint = lib
          .lookupFunction<
            Int32 Function(_Ptr, Pointer<Utf8>),
            int Function(_Ptr, Pointer<Utf8>)
          >('litert_lm_session_rewind_to_checkpoint'),
      runTextScoring = lib
          .lookupFunction<
            _Ptr Function(_Ptr, Pointer<Pointer<Utf8>>, Size, Bool),
            _Ptr Function(_Ptr, Pointer<Pointer<Utf8>>, int, bool)
          >('litert_lm_session_run_text_scoring'),
      responsesDelete = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'litert_lm_responses_delete',
          ),
      responsesNumTokenScoresAt = lib
          .lookupFunction<Int32 Function(_Ptr, Int32), int Function(_Ptr, int)>(
            'litert_lm_responses_get_num_token_scores_at',
          ),
      responsesTokenScoresAt = lib
          .lookupFunction<
            Pointer<Float> Function(_Ptr, Int32),
            Pointer<Float> Function(_Ptr, int)
          >('litert_lm_responses_get_token_scores_at');

  final DynamicLibrary lib;
  final _Ptr Function() sessionConfigCreate;
  final void Function(_Ptr) sessionConfigDelete;
  final void Function(_Ptr, bool) sessionConfigSetApplyPromptTemplate;
  final void Function(_Ptr, int) sessionConfigSetMaxOutputTokens;
  final void Function(_Ptr, _Ptr) sessionConfigSetSamplerParams;
  final _Ptr Function(int) samplerParamsCreate;
  final void Function(_Ptr) samplerParamsDelete;
  final void Function(_Ptr, int) samplerParamsSetTopK;
  final void Function(_Ptr, double) samplerParamsSetTopP;
  final void Function(_Ptr, double) samplerParamsSetTemperature;
  final void Function(_Ptr, int) samplerParamsSetSeed;
  final _Ptr Function() conversationConfigCreate;
  final void Function(_Ptr, _Ptr) conversationConfigSetSessionConfig;
  final void Function(_Ptr) conversationConfigDelete;
  final _Ptr Function(_Ptr, _Ptr) conversationCreate;
  final void Function(_Ptr) conversationDelete;
  final Pointer<Utf8> Function(_Ptr, Pointer<Utf8>) render;
  final _Ptr Function(_Ptr, _Ptr) engineCreateSession;
  final void Function(_Ptr) sessionDelete;
  final _Ptr Function(int, _Ptr, int) inputDataCreate;
  final void Function(_Ptr) inputDataDelete;
  final int Function(_Ptr, Pointer<_Ptr>, int) runPrefill;
  final int Function(_Ptr, Pointer<Utf8>) saveCheckpoint;
  final int Function(_Ptr, Pointer<Utf8>) rewindToCheckpoint;
  final _Ptr Function(_Ptr, Pointer<Pointer<Utf8>>, int, bool) runTextScoring;
  final void Function(_Ptr) responsesDelete;
  final int Function(_Ptr, int) responsesNumTokenScoresAt;
  final Pointer<Float> Function(_Ptr, int) responsesTokenScoresAt;

  /// A session config with litetune's greedy sampler — TOP_P, k 1, p 1,
  /// temperature 1, seed 0 — and, when given, [applyPromptTemplate].
  /// Scoring never samples; the sampler is set so that the session does not
  /// copy the bundle's, which LiteRT-LM's CPU sampler may refuse.
  _Ptr greedySessionConfig({required bool? applyPromptTemplate}) {
    final config = sessionConfigCreate();
    if (config == nullptr) {
      throw StateError(failure('litert_lm_session_config_create'));
    }
    if (applyPromptTemplate != null) {
      sessionConfigSetApplyPromptTemplate(config, applyPromptTemplate);
    }
    final sampler = samplerParamsCreate(_topP);
    if (sampler == nullptr) {
      sessionConfigDelete(config);
      throw StateError(failure('litert_lm_sampler_params_create'));
    }
    samplerParamsSetTopK(sampler, 1);
    samplerParamsSetTopP(sampler, 1);
    samplerParamsSetTemperature(sampler, 1);
    samplerParamsSetSeed(sampler, 0);
    sessionConfigSetSamplerParams(config, sampler);
    samplerParamsDelete(sampler);
    return config;
  }

  void prefill(_Ptr session, String text) {
    final bytes = utf8.encode(text);
    final data = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    final inputs = malloc<_Ptr>();
    var input = nullptr.cast<Void>();
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      input = inputDataCreate(_text, data.cast(), bytes.length);
      if (input == nullptr) {
        throw StateError(failure('litert_lm_input_data_create'));
      }
      inputs.value = input;
      checked(runPrefill(session, inputs, 1), 'litert_lm_session_run_prefill');
    } finally {
      if (input != nullptr) inputDataDelete(input);
      malloc.free(inputs);
      malloc.free(data);
    }
  }

  List<double> score(_Ptr session, String target) {
    final text = target.toNativeUtf8();
    final targets = malloc<Pointer<Utf8>>()..value = text;
    try {
      final responses = runTextScoring(session, targets, 1, true);
      if (responses == nullptr) {
        throw StateError(failure('litert_lm_session_run_text_scoring'));
      }
      try {
        final count = responsesNumTokenScoresAt(responses, 0);
        final scores = responsesTokenScoresAt(responses, 0);
        if (count < 0 || (count > 0 && scores == nullptr)) {
          throw StateError(
            'litert_lm_session_run_text_scoring returned $count token scores '
            'for ${jsonEncode(target)}',
          );
        }
        return Float64List.fromList(scores.asTypedList(count));
      } finally {
        responsesDelete(responses);
      }
    } finally {
      malloc.free(targets);
      malloc.free(text);
    }
  }

  void checked(int code, String call) {
    if (code != 0) throw StateError(failure(call, code: code));
  }

  /// [call] failed: its name, its status code when it returns one, and
  /// LiteRT-LM's last error, which is thread-local and so read here.
  String failure(String call, {int? code}) {
    String? message;
    if (lib.providesSymbol('litert_lm_get_last_error_message')) {
      final ptr = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'litert_lm_get_last_error_message',
          )();
      if (ptr != nullptr) message = ptr.toDartString();
    }
    return '$call failed${code == null ? '' : ' with $code'}'
        '${message == null || message.isEmpty ? '' : ': $message'}';
  }
}
