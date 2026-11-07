import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _dir = '/data/local/tmp/flutter_gemma_test';
const _gemma3n = '$_dir/gemma-3n-E2B-it-int4.litertlm';
const _gemma4 = '$_dir/gemma-4-E2B-it.litertlm';

typedef _CreateSettingsC =
    Pointer Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );
typedef _DeleteSettingsC = Void Function(Pointer);
typedef _SetMaxTokensC = Void Function(Pointer, Int32);
typedef _CreateEngineC = Pointer Function(Pointer);
typedef _DeleteEngineC = Void Function(Pointer);
typedef _CreateConvC = Pointer Function(Pointer, Pointer);
typedef _DeleteConvC = Void Function(Pointer);
typedef _SendMsgC = Pointer Function(Pointer, Pointer<Utf8>, Pointer);
typedef _GetRespStrC = Pointer<Utf8> Function(Pointer);
typedef _DeleteRespC = Void Function(Pointer);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DynamicLibrary lib;

  setUpAll(() {
    lib = DynamicLibrary.open('libLiteRtLm.so');
    print('Library loaded');
  });

  void testEngine(
    String name,
    String modelPath,
    String backend,
    String? vision,
    String? audio,
  ) {
    testWidgets('$name: b=$backend v=$vision a=$audio', (t) async {
      final createSettings = lib
          .lookupFunction<
            _CreateSettingsC,
            Pointer Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            )
          >('litert_lm_engine_settings_create');
      final deleteSettings = lib
          .lookupFunction<_DeleteSettingsC, void Function(Pointer)>(
            'litert_lm_engine_settings_delete',
          );
      final setMaxTokens = lib
          .lookupFunction<_SetMaxTokensC, void Function(Pointer, int)>(
            'litert_lm_engine_settings_set_max_num_tokens',
          );
      final createEngine = lib
          .lookupFunction<_CreateEngineC, Pointer Function(Pointer)>(
            'litert_lm_engine_create',
          );
      final deleteEngine = lib
          .lookupFunction<_DeleteEngineC, void Function(Pointer)>(
            'litert_lm_engine_delete',
          );
      final createConv = lib
          .lookupFunction<_CreateConvC, Pointer Function(Pointer, Pointer)>(
            'litert_lm_conversation_create',
          );
      final deleteConv = lib
          .lookupFunction<_DeleteConvC, void Function(Pointer)>(
            'litert_lm_conversation_delete',
          );
      final sendMsg = lib
          .lookupFunction<
            _SendMsgC,
            Pointer Function(Pointer, Pointer<Utf8>, Pointer)
          >('litert_lm_conversation_send_message');
      final getRespStr = lib
          .lookupFunction<_GetRespStrC, Pointer<Utf8> Function(Pointer)>(
            'litert_lm_json_response_get_string',
          );
      final deleteResp = lib
          .lookupFunction<_DeleteRespC, void Function(Pointer)>(
            'litert_lm_json_response_delete',
          );

      final modelPtr = modelPath.toNativeUtf8();
      final backendPtr = backend.toNativeUtf8();
      final visionPtr = vision?.toNativeUtf8();
      final audioPtr = audio?.toNativeUtf8();

      final settings = createSettings(
        modelPtr,
        backendPtr,
        visionPtr ?? Pointer.fromAddress(0).cast(),
        audioPtr ?? Pointer.fromAddress(0).cast(),
      );

      if (settings.address == 0) {
        print('| $name | $backend | $vision | $audio | SETTINGS_FAIL |');
        calloc.free(modelPtr);
        calloc.free(backendPtr);
        if (visionPtr != null) calloc.free(visionPtr);
        if (audioPtr != null) calloc.free(audioPtr);
        return;
      }

      setMaxTokens(settings, 4096);

      final engine = createEngine(settings);
      deleteSettings(settings);

      String result;
      if (engine.address == 0) {
        result = 'ENGINE_FAIL';
      } else {
        final conv = createConv(engine, nullptr);
        if (conv.address == 0) {
          result = 'CONV_FAIL';
        } else {
          // Try with image if vision enabled
          final msgJson =
              '{"role":"user","content":[{"type":"text","text":"Hi"}]}';
          final msg = msgJson.toNativeUtf8();
          final resp = sendMsg(conv, msg, nullptr);
          if (resp.address == 0) {
            result = 'SEND_NULL';
          } else {
            final str = getRespStr(resp);
            result =
                'OK: ${str.toDartString().substring(0, 60.clamp(0, str.toDartString().length))}';
            deleteResp(resp);
          }
          calloc.free(msg);
          deleteConv(conv);
        }
        deleteEngine(engine);
      }

      calloc.free(modelPtr);
      calloc.free(backendPtr);
      if (visionPtr != null) calloc.free(visionPtr);
      if (audioPtr != null) calloc.free(audioPtr);

      print('| $name | $backend | $vision | $audio | $result |');
    });
  }

  group('Gemma3n vision matrix', () {
    testEngine('g3n', _gemma3n, 'gpu', null, null);
    testEngine('g3n', _gemma3n, 'gpu', 'gpu', null);
    testEngine('g3n', _gemma3n, 'gpu', 'gpu', 'cpu');
    testEngine('g3n', _gemma3n, 'cpu', null, null);
    testEngine('g3n', _gemma3n, 'cpu', 'cpu', null);
  });

  group('Gemma4 full matrix', () {
    testEngine('g4', _gemma4, 'gpu', null, null);
    testEngine('g4', _gemma4, 'gpu', 'gpu', null);
    testEngine('g4', _gemma4, 'gpu', 'gpu', 'cpu');
    testEngine('g4', _gemma4, 'gpu', null, 'cpu');
    testEngine('g4', _gemma4, 'cpu', null, null);
  });
}
