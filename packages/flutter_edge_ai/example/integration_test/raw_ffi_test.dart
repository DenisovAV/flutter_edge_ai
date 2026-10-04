/// Raw FFI test — calls LiteRT-LM C API directly via dart:ffi,
/// exactly like the C++ test does. No plugin, no wrappers.
import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _modelPath =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';

// C function typedefs
typedef _CreateSettingsC =
    Pointer Function(Pointer<Utf8>, Pointer<Utf8>, Pointer, Pointer);
typedef _DeleteSettingsC = Void Function(Pointer);
typedef _SetMaxTokensC = Void Function(Pointer, Int32);
typedef _SetCacheDirC = Void Function(Pointer, Pointer<Utf8>);
typedef _CreateEngineC = Pointer Function(Pointer);
typedef _DeleteEngineC = Void Function(Pointer);
typedef _CreateConvC = Pointer Function(Pointer, Pointer);
typedef _DeleteConvC = Void Function(Pointer);

// Sync send_message
typedef _SendMsgC = Pointer Function(Pointer, Pointer<Utf8>, Pointer);
typedef _GetRespStrC = Pointer<Utf8> Function(Pointer);
typedef _DeleteRespC = Void Function(Pointer);

// Streaming callback: void(void*, const char*, bool, const char*)
// Using Uint8 for bool to test if Bool causes issues
typedef _StreamCallbackC =
    Void Function(Pointer<Void>, Pointer<Char>, Uint8, Pointer<Char>);

// send_message_stream
typedef _SendMsgStreamC =
    Int Function(
      Pointer,
      Pointer<Utf8>,
      Pointer,
      Pointer<NativeFunction<_StreamCallbackC>>,
      Pointer<Void>,
    );
typedef _SendMsgStreamDart =
    int Function(
      Pointer,
      Pointer<Utf8>,
      Pointer,
      Pointer<NativeFunction<_StreamCallbackC>>,
      Pointer<Void>,
    );

// stream_proxy_create
typedef _ProxyCreateC =
    Pointer<Void> Function(
      Pointer<NativeFunction<_StreamCallbackC>>,
      Pointer<Void>,
      Pointer<Pointer<NativeFunction<_StreamCallbackC>>>,
    );
typedef _ProxyFreeC = Void Function(Pointer<Char>);
typedef _ProxyFreeDart = void Function(Pointer<Char>);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DynamicLibrary lib;
  late DynamicLibrary proxyLib;
  late _ProxyCreateC proxyCreate;
  late _ProxyFreeDart proxyFree;

  setUpAll(() {
    lib = DynamicLibrary.open('LiteRtLm.framework/LiteRtLm');
    proxyLib = DynamicLibrary.open('StreamProxy.framework/StreamProxy');
    proxyCreate = proxyLib.lookupFunction<_ProxyCreateC, _ProxyCreateC>(
      'stream_proxy_create',
    );
    proxyFree = proxyLib.lookupFunction<_ProxyFreeC, _ProxyFreeDart>(
      'stream_proxy_free_string',
    );
  });

  group('Raw FFI - C API direct', () {
    testWidgets('Sync send_message', (tester) async {
      final createSettings = lib
          .lookupFunction<_CreateSettingsC, _CreateSettingsC>(
            'litert_lm_engine_settings_create',
          );
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

      // Create engine — exactly like C++ test
      final modelPtr = _modelPath.toNativeUtf8();
      final backendPtr = 'cpu'.toNativeUtf8();
      final settings = createSettings(modelPtr, backendPtr, nullptr, nullptr);
      expect(settings.address, isNot(0), reason: 'Settings creation failed');

      setMaxTokens(settings, 512);
      final cachePtr = '/tmp/litert_lm_cache'.toNativeUtf8();
      setCacheDir(settings, cachePtr);

      print('Creating engine...');
      final sw = Stopwatch()..start();
      final engine = createEngine(settings);
      sw.stop();
      print(
        'Engine: ${engine.address != 0 ? "OK" : "NULL"} (${sw.elapsedMilliseconds}ms)',
      );
      deleteSettings(settings);
      expect(engine.address, isNot(0), reason: 'Engine creation failed');

      // Create conversation with nullptr config — exactly like C++ test
      final conv = createConv(engine, nullptr);
      print('Conversation: ${conv.address != 0 ? "OK" : "NULL"}');
      expect(conv.address, isNot(0), reason: 'Conversation creation failed');

      // Sync send_message
      final msgJson =
          '{"role": "user", "content": [{"type": "text", "text": "What is 2+2?"}]}'
              .toNativeUtf8();
      print('Sending sync message...');
      final sw2 = Stopwatch()..start();
      final resp = sendMsg(conv, msgJson, nullptr);
      sw2.stop();
      print(
        'send_message: ${resp.address != 0 ? "OK" : "NULL"} (${sw2.elapsedMilliseconds}ms)',
      );

      if (resp.address != 0) {
        final str = getRespStr(resp);
        print('Response: ${str.toDartString()}');
        expect(str.toDartString(), contains('4'));
        deleteResp(resp);
      } else {
        fail('send_message returned null');
      }

      // Cleanup
      calloc.free(msgJson);
      deleteConv(conv);
      deleteEngine(engine);
      calloc.free(modelPtr);
      calloc.free(backendPtr);
      calloc.free(cachePtr);
      print('SYNC TEST PASSED');
    });

    testWidgets('Streaming send_message_stream', (tester) async {
      final createSettings = lib
          .lookupFunction<_CreateSettingsC, _CreateSettingsC>(
            'litert_lm_engine_settings_create',
          );
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
      final sendMsgStream = lib
          .lookupFunction<_SendMsgStreamC, _SendMsgStreamDart>(
            'litert_lm_conversation_send_message_stream',
          );

      final modelPtr = _modelPath.toNativeUtf8();
      final backendPtr = 'cpu'.toNativeUtf8();
      final settings = createSettings(modelPtr, backendPtr, nullptr, nullptr);
      setMaxTokens(settings, 512);
      final cachePtr = '/tmp/litert_lm_cache'.toNativeUtf8();
      setCacheDir(settings, cachePtr);

      final engine = createEngine(settings);
      deleteSettings(settings);
      expect(engine.address, isNot(0));

      final conv = createConv(engine, nullptr);
      expect(conv.address, isNot(0));

      // Streaming with proxy (strdup's strings so they survive until Dart processes them)
      final completer = Completer<String>();
      final chunks = <String>[];

      late final NativeCallable<_StreamCallbackC> callable;
      callable = NativeCallable<_StreamCallbackC>.listener((
        Pointer<Void> data,
        Pointer<Char> chunk,
        int isFinal,
        Pointer<Char> errorMsg,
      ) {
        print(
          '[callback] chunk=${chunk.address}, isFinal=$isFinal, error=${errorMsg.address}',
        );

        if (errorMsg != nullptr && errorMsg.address != 0) {
          final err = errorMsg.cast<Utf8>().toDartString();
          proxyFree(errorMsg); // free strdup'd string
          print('[callback] ERROR: $err');
          callable.close();
          completer.completeError(Exception(err));
          return;
        }

        if (chunk != nullptr && chunk.address != 0) {
          final text = chunk.cast<Utf8>().toDartString();
          proxyFree(chunk); // free strdup'd string
          print(
            '[callback] chunk text: ${text.substring(0, text.length.clamp(0, 80))}...',
          );
          chunks.add(text);
        }

        if (isFinal != 0) {
          print('[callback] FINAL');
          callable.close();
          completer.complete(chunks.join());
        }
      });

      // Create proxy
      final outProxyFn = calloc<Pointer<NativeFunction<_StreamCallbackC>>>();
      final proxyData = proxyCreate(
        callable.nativeFunction,
        nullptr,
        outProxyFn,
      );
      final proxyFnPtr = outProxyFn.value;
      calloc.free(outProxyFn);

      final msgJson =
          '{"role": "user", "content": [{"type": "text", "text": "What is 2+2?"}]}'
              .toNativeUtf8();
      print('Sending stream message...');
      final result = sendMsgStream(
        conv,
        msgJson,
        nullptr,
        proxyFnPtr,
        proxyData,
      );
      print('send_message_stream returned: $result');
      expect(result, 0);

      final response = await completer.future.timeout(
        const Duration(seconds: 60),
      );
      print('Stream response: $response');
      expect(response, isNotEmpty);

      calloc.free(msgJson);
      deleteConv(conv);
      deleteEngine(engine);
      calloc.free(modelPtr);
      calloc.free(backendPtr);
      calloc.free(cachePtr);
      print('STREAMING TEST PASSED');
    });
  });
}
