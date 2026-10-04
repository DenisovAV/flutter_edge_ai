import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _gemma3n =
    '/data/local/tmp/flutter_gemma_test/gemma-3n-E2B-it-int4.litertlm';
const _gemma4 = '/data/local/tmp/flutter_gemma_test/gemma-4-E2B-it.litertlm';
const _img = '/data/local/tmp/flutter_gemma_test/test_image.jpg';

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
    // Load with RTLD_GLOBAL so GPU accelerator can find LiteRt* symbols
    final proxy = DynamicLibrary.open('libStreamProxy.so');
    final loadGlobal = proxy
        .lookupFunction<
          Pointer Function(Pointer<Utf8>),
          Pointer Function(Pointer<Utf8>)
        >('stream_proxy_load_global');

    // Load main lib with RTLD_GLOBAL
    var p = 'libLiteRtLm.so'.toNativeUtf8();
    loadGlobal(p);
    calloc.free(p);

    // Pre-load GPU accelerator with RTLD_GLOBAL BEFORE engine_create
    p = 'libLiteRtGpuAccelerator.so'.toNativeUtf8();
    loadGlobal(p);
    calloc.free(p);
    p = 'libLiteRtOpenClAccelerator.so'.toNativeUtf8();
    loadGlobal(p);
    calloc.free(p);

    lib = DynamicLibrary.open('libLiteRtLm.so');
    print('Library loaded (RTLD_GLOBAL + GPU preloaded)');
  });

  void runTest(
    String name,
    String modelPath,
    String backend,
    String? vision,
    String? audio, {
    bool sendImage = false,
  }) {
    testWidgets('$name: b=$backend v=$vision a=$audio img=$sendImage', (
      t,
    ) async {
      final cs = lib
          .lookupFunction<
            _CreateSettingsC,
            Pointer Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            )
          >('litert_lm_engine_settings_create');
      final ds = lib.lookupFunction<_DeleteSettingsC, void Function(Pointer)>(
        'litert_lm_engine_settings_delete',
      );
      final mt = lib
          .lookupFunction<_SetMaxTokensC, void Function(Pointer, int)>(
            'litert_lm_engine_settings_set_max_num_tokens',
          );
      final ce = lib.lookupFunction<_CreateEngineC, Pointer Function(Pointer)>(
        'litert_lm_engine_create',
      );
      final de = lib.lookupFunction<_DeleteEngineC, void Function(Pointer)>(
        'litert_lm_engine_delete',
      );
      final cc = lib
          .lookupFunction<_CreateConvC, Pointer Function(Pointer, Pointer)>(
            'litert_lm_conversation_create',
          );
      final dc = lib.lookupFunction<_DeleteConvC, void Function(Pointer)>(
        'litert_lm_conversation_delete',
      );
      final sm = lib
          .lookupFunction<
            _SendMsgC,
            Pointer Function(Pointer, Pointer<Utf8>, Pointer)
          >('litert_lm_conversation_send_message');
      final gr = lib
          .lookupFunction<_GetRespStrC, Pointer<Utf8> Function(Pointer)>(
            'litert_lm_json_response_get_string',
          );
      final dr = lib.lookupFunction<_DeleteRespC, void Function(Pointer)>(
        'litert_lm_json_response_delete',
      );

      final mp = modelPath.toNativeUtf8();
      final bp = backend.toNativeUtf8();
      final vp = vision?.toNativeUtf8();
      final ap = audio?.toNativeUtf8();

      final s = cs(
        mp,
        bp,
        vp ?? Pointer.fromAddress(0).cast(),
        ap ?? Pointer.fromAddress(0).cast(),
      );
      if (s.address == 0) {
        print('| $name | $backend | $vision | $audio | SETTINGS_FAIL |');
        return;
      }

      mt(s, 4096);

      final e = ce(s);
      ds(s);
      if (e.address == 0) {
        print('| $name | $backend | $vision | $audio | ENGINE_FAIL |');
        return;
      }

      final conv = cc(e, nullptr);
      if (conv.address == 0) {
        de(e);
        print('| $name | $backend | $vision | $audio | CONV_FAIL |');
        return;
      }

      String msgJson;
      if (sendImage && File(_img).existsSync()) {
        final imgBytes = File(_img).readAsBytesSync();
        final b64 = base64Encode(imgBytes);
        msgJson =
            '{"role":"user","content":[{"type":"image","blob":"$b64"},{"type":"text","text":"What is in this image?"}]}';
      } else {
        msgJson = '{"role":"user","content":[{"type":"text","text":"Hi"}]}';
      }

      final msg = msgJson.toNativeUtf8();
      final r = sm(conv, msg, nullptr);
      String result;
      if (r.address == 0) {
        result = 'SEND_NULL';
      } else {
        final str = gr(r).toDartString();
        dr(r);
        result = 'OK: ${str.substring(0, str.length.clamp(0, 80))}';
      }

      calloc.free(msg);
      dc(conv);
      de(e);
      calloc.free(mp);
      calloc.free(bp);
      if (vp != null) calloc.free(vp);
      if (ap != null) calloc.free(ap);

      print(
        '| $name | $backend | $vision | $audio | img=$sendImage | $result |',
      );
    });
  }

  // Gemma3n — Kotlin AAR vision works with this model
  group('Gemma3n vision', () {
    runTest('g3n', _gemma3n, 'gpu', null, null);
    runTest('g3n', _gemma3n, 'gpu', 'gpu', null);
    runTest('g3n', _gemma3n, 'cpu', 'gpu', null);
  });

  // Gemma4
  group('Gemma4 vision', () {
    runTest('g4', _gemma4, 'gpu', null, null);
    runTest('g4', _gemma4, 'gpu', 'gpu', null);
  });
}
