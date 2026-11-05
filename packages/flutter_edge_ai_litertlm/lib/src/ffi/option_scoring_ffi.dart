// The native calls behind InferenceModel.createDecider on LiteRT-LM: render a
// decision prompt, and score options as the model's reply through the session
// API. Both block for the whole native call (a prefill, one scoring pass per
// option), so they run on a spawned isolate, as the engine create does.
//
// Through the generated C API 1.0 bindings (`litert_lm_bindings.dart`): every
// call returns a status, checked here, and writes its result through an
// out-parameter.
//
// What each step does mirrors litetune's ENGINE_SCRIPT
// (`decision_scripts.py`): a session with no prompt template and a greedy
// TOP_P sampler, the prompt prefilled, a checkpoint, then each target scored
// and rewound. LiteRT-LM 0.18.0 needed the prompt's last token prefilled again
// after the checkpoint (#3561, mode `once`); 0.19.0 scores right after the
// prefill, which `option_scoring_self_check.dart` checks.
//
// The decider SPI (OptionScoringRun) is @experimental.
// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';

import 'litert_lm_bindings.dart';
import 'litert_lm_client.dart' show LiteRtLmLastErrorRead;
import 'litert_lm_library.dart';
import 'litert_lm_status.dart';

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
    final n = _Native(LiteRtLmBindings(openLiteRtLmLibrary()));
    n.b.litert_lm_clear_last_error();
    final sessionConfig = n.greedySessionConfig(applyPromptTemplate: null);
    final Pointer<LiteRtLmConversation> conversation;
    try {
      n.setter(
        'litert_lm_session_config_set_max_output_tokens',
        n.b.litert_lm_session_config_set_max_output_tokens(sessionConfig, 1),
      );
      final config = n.create(
        'litert_lm_conversation_config_create',
        n.b.litert_lm_conversation_config_create,
      );
      try {
        n.setter(
          'litert_lm_conversation_config_set_session_config',
          n.b.litert_lm_conversation_config_set_session_config(
            config,
            sessionConfig,
          ),
        );
        conversation = n.create(
          'litert_lm_conversation_create',
          (out) => n.b.litert_lm_conversation_create(
            Pointer.fromAddress(engineAddr),
            config,
            out,
          ),
        );
      } finally {
        n.b.litert_lm_conversation_config_delete(config);
      }
    } finally {
      n.b.litert_lm_session_config_delete(sessionConfig);
    }
    final message = jsonEncode({'role': 'user', 'content': content})
        .toNativeUtf8();
    try {
      final rendered = n.pointer<Char>(
        'litert_lm_conversation_render_message_to_string',
        (out) => n.b.litert_lm_conversation_render_message_to_string(
          conversation,
          message.cast(),
          out,
        ),
      );
      if (rendered == nullptr) {
        throw StateError(
          'litert_lm_conversation_render_message_to_string returned no text',
        );
      }
      // Owned by the conversation: copied before it is deleted.
      return nativeText(rendered.cast());
    } finally {
      malloc.free(message);
      n.b.litert_lm_conversation_delete(conversation);
    }
  });
}

/// Scores each of [targets] after [prompt] in one fresh session; see
/// `OptionScorer.score`.
///
/// [stopFlagAddr] is the address of an `Int32` the caller sets to non-zero to
/// stop the run: it is read before the prefill and before each target, and a
/// set flag fails the run with `DeciderCancelledException` — the native call
/// in progress is not interrupted.
Future<OptionScoringRun> scoreTargetsOffMainIsolate({
  required int engineAddr,
  required String prompt,
  required List<String> targets,
  required int stopFlagAddr,
}) {
  final isolateLogLevel = edgeAiLogLevel;
  return Isolate.run(() {
    edgeAiLogLevel = isolateLogLevel;
    final stop = Pointer<Int32>.fromAddress(stopFlagAddr);
    void stopIfAsked() {
      if (stop.value != 0) {
        throw const DeciderCancelledException('The scoring was stopped.');
      }
    }

    stopIfAsked();
    final n = _Native(LiteRtLmBindings(openLiteRtLmLibrary()));
    n.b.litert_lm_clear_last_error();
    final config = n.greedySessionConfig(applyPromptTemplate: false);
    final Pointer<LiteRtLmSession> session;
    try {
      session = n.create(
        'litert_lm_engine_create_session',
        (out) => n.b.litert_lm_engine_create_session(
          Pointer.fromAddress(engineAddr),
          config,
          out,
        ),
      );
    } finally {
      n.b.litert_lm_session_config_delete(config);
    }
    final label = _checkpoint.toNativeUtf8();
    try {
      final prefillWatch = Stopwatch()..start();
      n.prefill(session, prompt);
      if (targets.length > 1) {
        n.check(
          'litert_lm_session_save_checkpoint',
          n.b.litert_lm_session_save_checkpoint(session, label.cast()),
        );
      }
      prefillWatch.stop();
      final scoreWatch = Stopwatch()..start();
      final scores = <List<double>>[];
      for (var i = 0; i < targets.length; i++) {
        stopIfAsked();
        scores.add(n.score(session, targets[i]));
        if (i < targets.length - 1) {
          n.check(
            'litert_lm_session_rewind_to_checkpoint',
            n.b.litert_lm_session_rewind_to_checkpoint(session, label.cast()),
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
      n.b.litert_lm_session_delete(session);
    }
  });
}

/// The C calls, made through [b] on the isolate that makes them. A failure
/// is a [StateError] naming the call, its status and LiteRT-LM's last error,
/// which is thread-local and so read here.
final class _Native {
  _Native(this.b);

  final LiteRtLmBindings b;

  Never _fail(LiteRtLmCallException e) => throw StateError(e.toString());

  void check(String call, int code) {
    try {
      checkLiteRtLmStatus(call, code, b.lastError);
    } on LiteRtLmCallException catch (e) {
      _fail(e);
    }
  }

  void setter(String call, int code) =>
      checkLiteRtLmSetter(call, code, b.lastError);

  Pointer<T> create<T extends NativeType>(
    String call,
    int Function(Pointer<Pointer<T>> out) make,
  ) {
    try {
      return createLiteRtLm(call, make, b.lastError);
    } on LiteRtLmCallException catch (e) {
      _fail(e);
    }
  }

  Pointer<T> pointer<T extends NativeType>(
    String call,
    int Function(Pointer<Pointer<T>> out) get,
  ) {
    try {
      return readLiteRtLmPointer(call, get, b.lastError);
    } on LiteRtLmCallException catch (e) {
      _fail(e);
    }
  }

  /// A session config with litetune's greedy sampler — TOP_P, k 1, p 1,
  /// temperature 1, seed 0 — and, when given, [applyPromptTemplate].
  /// Scoring never samples; the sampler is set so that the session does not
  /// copy the bundle's, which LiteRT-LM's CPU sampler may refuse.
  Pointer<LiteRtLmSessionConfig> greedySessionConfig({
    required bool? applyPromptTemplate,
  }) {
    final config = create(
      'litert_lm_session_config_create',
      b.litert_lm_session_config_create,
    );
    try {
      if (applyPromptTemplate != null) {
        setter(
          'litert_lm_session_config_set_apply_prompt_template',
          b.litert_lm_session_config_set_apply_prompt_template(
            config,
            applyPromptTemplate,
          ),
        );
      }
      final sampler = create<LiteRtLmSamplerParams>(
        'litert_lm_sampler_params_create',
        (out) => b.litert_lm_sampler_params_create(
          LiteRtLmSamplerType.kLiteRtLmSamplerTypeTopP,
          out,
        ),
      );
      try {
        setter(
          'litert_lm_sampler_params_set_top_k',
          b.litert_lm_sampler_params_set_top_k(sampler, 1),
        );
        setter(
          'litert_lm_sampler_params_set_top_p',
          b.litert_lm_sampler_params_set_top_p(sampler, 1),
        );
        setter(
          'litert_lm_sampler_params_set_temperature',
          b.litert_lm_sampler_params_set_temperature(sampler, 1),
        );
        setter(
          'litert_lm_sampler_params_set_seed',
          b.litert_lm_sampler_params_set_seed(sampler, 0),
        );
        setter(
          'litert_lm_session_config_set_sampler_params',
          b.litert_lm_session_config_set_sampler_params(config, sampler),
        );
      } finally {
        b.litert_lm_sampler_params_delete(sampler);
      }
    } catch (_) {
      b.litert_lm_session_config_delete(config);
      rethrow;
    }
    return config;
  }

  void prefill(Pointer<LiteRtLmSession> session, String text) {
    final bytes = utf8.encode(text);
    final data = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    final inputs = malloc<Pointer<LiteRtLmInputData>>();
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      final input = create<LiteRtLmInputData>(
        'litert_lm_input_data_create',
        (out) => b.litert_lm_input_data_create(
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
          data.cast(),
          bytes.length,
          out,
        ),
      );
      try {
        inputs.value = input;
        check(
          'litert_lm_session_run_prefill',
          b.litert_lm_session_run_prefill(session, inputs, 1),
        );
      } finally {
        b.litert_lm_input_data_delete(input);
      }
    } finally {
      malloc.free(inputs);
      malloc.free(data);
    }
  }

  List<double> score(Pointer<LiteRtLmSession> session, String target) {
    final text = target.toNativeUtf8();
    final targets = malloc<Pointer<Char>>()..value = text.cast();
    try {
      final responses = create<LiteRtLmResponses>(
        'litert_lm_session_run_text_scoring',
        (out) => b.litert_lm_session_run_text_scoring(
          session,
          targets,
          1,
          true,
          out,
        ),
      );
      try {
        final count = malloc<Size>();
        final values = malloc<Pointer<Float>>();
        try {
          check(
            'litert_lm_responses_get_num_token_scores_at',
            b.litert_lm_responses_get_num_token_scores_at(responses, 0, count),
          );
          check(
            'litert_lm_responses_get_token_scores_at',
            b.litert_lm_responses_get_token_scores_at(responses, 0, values),
          );
          final n = count.value;
          final scores = values.value;
          if (n <= 0 || scores == nullptr) {
            throw StateError(
              'litert_lm_session_run_text_scoring returned $n token scores',
            );
          }
          return Float64List.fromList(scores.asTypedList(n));
        } finally {
          malloc.free(count);
          malloc.free(values);
        }
      } finally {
        b.litert_lm_responses_delete(responses);
      }
    } finally {
      malloc.free(targets);
      malloc.free(text);
    }
  }
}

/// The NUL-terminated native string at [ptr], decoded as UTF-8 with any
/// malformed bytes replaced, so that a broken byte never hides what it was
/// part of.
String nativeText(Pointer<Uint8> ptr) {
  var length = 0;
  while (ptr[length] != 0) {
    length++;
  }
  return utf8.decode(ptr.asTypedList(length), allowMalformed: true);
}
