// Kotlin's Session API (Engine.createSession, Session.runPrefill/runDecode/
// generateContent/generateContentStream/cancelProcess/clone) over the C API's
// session calls. Each blocking call runs on a spawned isolate, as a
// conversation's create and send do: a prefill can take seconds, and the
// calling isolate is an app's UI thread. The client (litert_lm_client.dart)
// holds its native lock around each of them.

import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../runtime/runtime_log.dart';
import '../runtime/types.dart' show Sampler;
import 'litert_lm_bindings.dart';
import '../api/session.dart';
import 'litert_lm_client.dart' show LiteRtLmFfiClient, LiteRtLmLastErrorRead;
import 'litert_lm_library.dart';
import 'litert_lm_status.dart';
import 'option_scoring_ffi.dart' show nativeText;
import 'send_options.dart';

/// One input of a session's prefill, as plain values that cross isolates:
/// [type] is `LiteRtLmInputDataType`'s value (0 text, 1 image, 3 audio).
typedef SessionInput = ({int type, Uint8List bytes});

/// What a session is created with: the resolved sampler, the LoRA paths and
/// the speculative decoding fields, each null when not set.
typedef SessionSettings = ({
  Sampler sampler,
  String? loraPath,
  String? audioLoraPath,
  int? speculativeMode,
  double? speculativeLenience,
});

/// The outcome of a session call on the spawned isolate: [code] 0 and the
/// result's [address] or [text], else the status and LiteRT-LM's last error,
/// which is thread-local and so is read there.
typedef SessionCallResult = ({
  int code,
  int address,
  String? text,
  String? message,
});

/// Creates a session on the engine at [engineAddr] (`litert_lm_engine_create_session`).
Future<SessionCallResult> createSessionOffMainIsolate({
  required int engineAddr,
  required SessionSettings settings,
}) => _run((b) {
  final config = createLiteRtLm(
    'litert_lm_session_config_create',
    b.litert_lm_session_config_create,
    b.lastError,
  );
  try {
    void check(String name, int code) =>
        checkLiteRtLmSetter(name, code, b.lastError);
    // Always a resolved TOP_P sampler, as a conversation sends one: a config
    // without one makes LiteRT-LM copy the bundle's whole, which its CPU
    // sampler may refuse.
    final sampler = createLiteRtLm<LiteRtLmSamplerParams>(
      'litert_lm_sampler_params_create',
      (out) => b.litert_lm_sampler_params_create(
        LiteRtLmSamplerType.kLiteRtLmSamplerTypeTopP,
        out,
      ),
      b.lastError,
    );
    try {
      final s = settings.sampler;
      check(
        'litert_lm_sampler_params_set_top_k',
        b.litert_lm_sampler_params_set_top_k(sampler, s.topK),
      );
      check(
        'litert_lm_sampler_params_set_top_p',
        b.litert_lm_sampler_params_set_top_p(sampler, s.topP),
      );
      check(
        'litert_lm_sampler_params_set_temperature',
        b.litert_lm_sampler_params_set_temperature(sampler, s.temperature),
      );
      check(
        'litert_lm_sampler_params_set_seed',
        b.litert_lm_sampler_params_set_seed(sampler, s.randomSeed),
      );
      check(
        'litert_lm_session_config_set_sampler_params',
        b.litert_lm_session_config_set_sampler_params(config, sampler),
      );
    } finally {
      b.litert_lm_sampler_params_delete(sampler);
    }
    for (final (name, path, set) in [
      (
        'litert_lm_session_config_set_lora_path',
        settings.loraPath,
        b.litert_lm_session_config_set_lora_path,
      ),
      (
        'litert_lm_session_config_set_audio_lora_path',
        settings.audioLoraPath,
        b.litert_lm_session_config_set_audio_lora_path,
      ),
    ]) {
      if (path == null) continue;
      final p = path.toNativeUtf8();
      try {
        check(name, set(config, p.cast()));
      } finally {
        malloc.free(p);
      }
    }
    if (settings.speculativeMode != null ||
        settings.speculativeLenience != null) {
      final speculative = createLiteRtLm(
        'litert_lm_speculative_decoding_config_create',
        b.litert_lm_speculative_decoding_config_create,
        b.lastError,
      );
      try {
        applySpeculativeDecodingFields(
          b,
          speculative,
          mode: settings.speculativeMode,
          lenience: settings.speculativeLenience,
        );
        check(
          'litert_lm_session_config_set_speculative_decoding_config',
          b.litert_lm_session_config_set_speculative_decoding_config(
            config,
            speculative,
          ),
        );
      } finally {
        b.litert_lm_speculative_decoding_config_delete(speculative);
      }
    }
    final out = calloc<Pointer<LiteRtLmSession>>();
    try {
      final code = b.litert_lm_engine_create_session(
        Pointer.fromAddress(engineAddr),
        config,
        out,
      );
      return _result(b, code, address: code == 0 ? out.value.address : 0);
    } finally {
      calloc.free(out);
    }
  } finally {
    b.litert_lm_session_config_delete(config);
  }
});

/// `litert_lm_session_run_prefill` with [inputs].
Future<SessionCallResult> sessionPrefillOffMainIsolate({
  required int sessionAddr,
  required List<SessionInput> inputs,
}) => _run(
  (b) => _withInputs(
    b,
    inputs,
    (array, n) => _result(
      b,
      b.litert_lm_session_run_prefill(
        Pointer.fromAddress(sessionAddr),
        array,
        n,
      ),
    ),
  ),
);

/// `litert_lm_session_run_decode`, or `litert_lm_session_generate_content`
/// when [inputs] is given; the text of the first candidate.
Future<SessionCallResult> sessionDecodeOffMainIsolate({
  required int sessionAddr,
  List<SessionInput>? inputs,
}) => _run((b) {
  final out = calloc<Pointer<LiteRtLmResponses>>();
  try {
    final session = Pointer<LiteRtLmSession>.fromAddress(sessionAddr);
    final code = inputs == null
        ? b.litert_lm_session_run_decode(session, out)
        : _withInputs(
            b,
            inputs,
            (array, n) =>
                b.litert_lm_session_generate_content(session, array, n, out),
          );
    if (code != 0) return _result(b, code);
    final responses = out.value;
    try {
      final text = readLiteRtLmPointer<Char>(
        'litert_lm_responses_get_response_text_at',
        (p) => b.litert_lm_responses_get_response_text_at(responses, 0, p),
        b.lastError,
      );
      return (
        code: 0,
        address: 0,
        text: text == nullptr ? '' : nativeText(text.cast()),
        message: null,
      );
    } finally {
      b.litert_lm_responses_delete(responses);
    }
  } finally {
    calloc.free(out);
  }
});

/// `litert_lm_session_clone`.
Future<SessionCallResult> sessionCloneOffMainIsolate({
  required int sessionAddr,
}) => _run((b) {
  final out = calloc<Pointer<LiteRtLmSession>>();
  try {
    final code = b.litert_lm_session_clone(
      Pointer.fromAddress(sessionAddr),
      out,
    );
    return _result(b, code, address: code == 0 ? out.value.address : 0);
  } finally {
    calloc.free(out);
  }
});

/// `litert_lm_session_generate_content_stream` with [inputs], streaming to
/// the C callback at [callbackAddr] with [callbackDataAddr] (a stream proxy).
/// Native prefills before it returns; the decode streams after.
Future<SessionCallResult> sessionGenerateStreamOffMainIsolate({
  required int sessionAddr,
  required List<SessionInput> inputs,
  required int callbackAddr,
  required int callbackDataAddr,
}) => _run(
  (b) => _withInputs(
    b,
    inputs,
    (array, n) => _result(
      b,
      b.litert_lm_session_generate_content_stream(
        Pointer.fromAddress(sessionAddr),
        array,
        n,
        Pointer.fromAddress(callbackAddr),
        Pointer.fromAddress(callbackDataAddr),
      ),
    ),
  ),
);

/// [text] as a session input.
SessionInput sessionText(String text) => (
  type: LiteRtLmInputDataType.kLiteRtLmInputDataTypeText.value,
  bytes: Uint8List.fromList(utf8.encode(text)),
);

Future<SessionCallResult> _run(
  SessionCallResult Function(LiteRtLmBindings b) body,
) {
  final level = currentRuntimeLogLevel();
  return Isolate.run(() {
    runtimeLogLevel = level;
    // Plain open: only called on a client whose engine is loaded.
    final b = LiteRtLmBindings(openLiteRtLmLibrary());
    b.litert_lm_clear_last_error();
    try {
      return body(b);
    } on LiteRtLmCallException catch (e) {
      // An OK with no result is a failure too, never an address 0 success.
      return (
        code: e.code == 0 ? -1 : e.code,
        address: 0,
        text: null,
        message: '$e',
      );
    }
  });
}

SessionCallResult _result(LiteRtLmBindings b, int code, {int address = 0}) => (
  code: code,
  address: address,
  text: null,
  message: code == 0 ? null : b.lastError(),
);

/// Runs [body] with [inputs] as a native `LiteRtLmInputData*` array, created
/// and deleted here (native copies what it keeps).
T _withInputs<T>(
  LiteRtLmBindings b,
  List<SessionInput> inputs,
  T Function(Pointer<Pointer<LiteRtLmInputData>> array, int n) body,
) {
  final array = calloc<Pointer<LiteRtLmInputData>>(
    inputs.isEmpty ? 1 : inputs.length,
  );
  final made = <Pointer<LiteRtLmInputData>>[];
  try {
    for (final (i, input) in inputs.indexed) {
      final data = malloc<Uint8>(input.bytes.isEmpty ? 1 : input.bytes.length);
      try {
        data.asTypedList(input.bytes.length).setAll(0, input.bytes);
        final created = createLiteRtLm<LiteRtLmInputData>(
          'litert_lm_input_data_create',
          (out) => b.litert_lm_input_data_create(
            LiteRtLmInputDataType.fromValue(input.type),
            data.cast(),
            input.bytes.length,
            out,
          ),
          b.lastError,
        );
        made.add(created);
        array[i] = created;
      } finally {
        malloc.free(data);
      }
    }
    return body(array, inputs.length);
  } finally {
    made.forEach(b.litert_lm_input_data_delete);
    calloc.free(array);
  }
}

/// A [SessionHandle] over a native session of [client], at [address].
/// [vision] and [audio] say whether the engine loaded those encoders: an
/// input for one it did not load is refused before native.
final class NativeSessionHandle implements SessionHandle {
  NativeSessionHandle(
    this.client,
    this.address, {
    required this.vision,
    required this.audio,
  });

  final LiteRtLmFfiClient client;
  final int address;
  final bool vision;
  final bool audio;

  List<SessionInput> _native(List<InputData> inputs) => [
    for (final input in inputs)
      switch (input) {
        TextInputData(:final text) => sessionText(text),
        ImageInputData(:final bytes) when vision => (
          type: LiteRtLmInputDataType.kLiteRtLmInputDataTypeImage.value,
          bytes: bytes,
        ),
        AudioInputData(:final bytes) when audio => (
          type: LiteRtLmInputDataType.kLiteRtLmInputDataTypeAudio.value,
          bytes: bytes,
        ),
        ImageInputData() => throw UnsupportedError(
          'This engine loaded no vision encoder: create it with a '
          'visionBackend to prefill images.',
        ),
        AudioInputData() => throw UnsupportedError(
          'This engine loaded no audio encoder: create it with an '
          'audioBackend to prefill audio.',
        ),
      },
  ];

  @override
  Future<void> runPrefill(List<InputData> inputs) =>
      client.sessionPrefill(address, _native(inputs));

  @override
  Future<String> runDecode() => client.sessionDecode(address);

  @override
  Future<String> generateContent(List<InputData> inputs) =>
      client.sessionDecode(address, inputs: _native(inputs));

  @override
  Stream<String> generateContentStream(List<InputData> inputs) =>
      client.sessionGenerateStream(address, _native(inputs));

  @override
  void cancelProcess() => client.sessionCancel(address);

  @override
  Future<SessionHandle> clone() async => NativeSessionHandle(
    client,
    await client.sessionClone(address),
    vision: vision,
    audio: audio,
  );

  @override
  Future<void> close() => client.sessionDelete(address);
}

/// [inputs] as [handle] hands them to native, for tests.
List<SessionInput> nativeSessionInputsForTest(
  NativeSessionHandle handle,
  List<InputData> inputs,
) => handle._native(inputs);
