import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _gemma4Path =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/gemma-4-E2B-it.litertlm';
const _gemma3nPath =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/gemma-3n-E2B-it-int4.litertlm';

typedef _CreateSettingsC =
    Pointer Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );
typedef _DeleteSettingsC = Void Function(Pointer);
typedef _SetMaxTokensC = Void Function(Pointer, Int32);
typedef _SetCacheDirC = Void Function(Pointer, Pointer<Utf8>);
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
    lib = DynamicLibrary.open('LiteRtLm.framework/LiteRtLm');
  });

  void runTest(
    String name,
    String modelPath,
    String backend,
    String? vision,
    String? audio,
  ) {
    testWidgets('$name: $backend v=$vision a=$audio', (t) async {
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
      final setCacheDir = lib
          .lookupFunction<_SetCacheDirC, void Function(Pointer, Pointer<Utf8>)>(
            'litert_lm_engine_settings_set_cache_dir',
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

      String result;
      if (settings.address == 0) {
        result = 'SETTINGS_FAIL';
      } else {
        setMaxTokens(settings, 512);
        final cachePtr = '/tmp/litert_lm_cache'.toNativeUtf8();
        setCacheDir(settings, cachePtr);

        final engine = createEngine(settings);
        deleteSettings(settings);

        if (engine.address == 0) {
          result = 'ENGINE_FAIL';
        } else {
          final conv = createConv(engine, nullptr);
          if (conv.address == 0) {
            result = 'CONV_FAIL';
          } else {
            final msgJson =
                '{"role":"user","content":[{"type":"text","text":"What is 2+2?"}]}'
                    .toNativeUtf8();
            final resp = sendMsg(conv, msgJson, nullptr);
            if (resp.address == 0) {
              result = 'SEND_NULL';
            } else {
              final str = getRespStr(resp);
              final text = str.toDartString();
              deleteResp(resp);
              result = text.contains('"text"')
                  ? 'OK: ${text.substring(0, text.length.clamp(0, 60))}'
                  : 'OK: $text';
            }
            calloc.free(msgJson);
            deleteConv(conv);
          }
          deleteEngine(engine);
        }
        calloc.free(cachePtr);
      }

      calloc.free(modelPtr);
      calloc.free(backendPtr);
      if (visionPtr != null) calloc.free(visionPtr);
      if (audioPtr != null) calloc.free(audioPtr);

      print('| $name | $backend | $vision | $audio | $result |');
    });
  }

  group('Gemma 4 E2B', () {
    runTest('g4', _gemma4Path, 'cpu', null, null);
    runTest('g4', _gemma4Path, 'cpu', 'cpu', null);
    runTest('g4', _gemma4Path, 'cpu', null, 'cpu');
    runTest('g4', _gemma4Path, 'cpu', 'cpu', 'cpu');
    runTest('g4', _gemma4Path, 'gpu', null, null);
    runTest('g4', _gemma4Path, 'gpu', 'gpu', null);
    runTest('g4', _gemma4Path, 'gpu', null, 'cpu');
    runTest('g4', _gemma4Path, 'gpu', 'gpu', 'cpu');
  });

  group('Gemma 3n E2B', () {
    runTest('g3n', _gemma3nPath, 'cpu', null, null);
    runTest('g3n', _gemma3nPath, 'cpu', 'cpu', null);
    runTest('g3n', _gemma3nPath, 'cpu', null, 'cpu');
    runTest('g3n', _gemma3nPath, 'cpu', 'cpu', 'cpu');
    runTest('g3n', _gemma3nPath, 'gpu', null, null);
    runTest('g3n', _gemma3nPath, 'gpu', 'gpu', null);
    runTest('g3n', _gemma3nPath, 'gpu', null, 'cpu');
    runTest('g3n', _gemma3nPath, 'gpu', 'gpu', 'cpu');
  });
}
