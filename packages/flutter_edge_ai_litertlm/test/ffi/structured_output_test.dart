// Calls the protected engine SPI to verify the package's qualification table.
// ignore_for_file: invalid_use_of_protected_member

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/structured_output_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the generated C API 1.0 bindings pass both constraint setters', () {
    var provider = -1;
    var constraintType = -1;
    var constraintAddress = 0;
    final keep = <NativeCallable>[];
    Pointer<Void> retain(NativeCallable callable) {
      keep.add(callable);
      return callable.nativeFunction.cast();
    }

    final symbols = <String, Pointer<Void>>{
      'litert_lm_conversation_config_set_constraint_provider': retain(
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmConversationConfig>, UnsignedInt)
        >.isolateLocal((Pointer<LiteRtLmConversationConfig> _, int value) {
          provider = value;
          return 0;
        }, exceptionalReturn: 1),
      ),
      'litert_lm_conversation_optional_args_set_constraint': retain(
        NativeCallable<
          UnsignedInt Function(
            Pointer<LiteRtLmConversationOptionalArgs>,
            UnsignedInt,
            Pointer<Char>,
          )
        >.isolateLocal((
          Pointer<LiteRtLmConversationOptionalArgs> _,
          int type,
          Pointer<Char> text,
        ) {
          constraintType = type;
          constraintAddress = text.address;
          return 0;
        }, exceptionalReturn: 1),
      ),
    };
    addTearDown(() {
      for (final callable in keep) {
        callable.close();
      }
    });
    final bindings = LiteRtLmBindings.fromLookup(
      <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
    );
    final schema = '{"type":"string"}'.toNativeUtf8();
    addTearDown(() => calloc.free(schema));

    expect(
      bindings.litert_lm_conversation_config_set_constraint_provider(
        Pointer.fromAddress(0x10),
        LiteRtLmConstraintProviderType
            .kLiteRtLmConstraintProviderTypeLlGuidance,
      ),
      0,
    );
    expect(
      bindings.litert_lm_conversation_optional_args_set_constraint(
        Pointer.fromAddress(0x20),
        LiteRtLmConstraintType.kLiteRtLmConstraintTypeJsonSchema,
        schema.cast(),
      ),
      0,
    );
    expect(provider, 1);
    expect(constraintType, 2);
    expect(
      Pointer<Utf8>.fromAddress(constraintAddress).toDartString(),
      '{"type":"string"}',
    );
  });

  test('only the device-run table advertises the whole dialect', () {
    expect(liteRtLmStructuredOutputRows, isNotEmpty);
    for (final row in liteRtLmStructuredOutputCandidateRows) {
      final support = liteRtLmStructuredOutputSupport(
        abi: row.abi,
        backend: row.backend,
        androidGpu: row.androidGpu,
        npuVendor: row.npuVendor,
      );
      if (liteRtLmStructuredOutputRows.contains(row)) {
        expect(support.isSupported, isTrue, reason: '$row');
        expect(support.keywords, ResponseFormat.dialect, reason: '$row');
      } else {
        expect(support.isSupported, isFalse, reason: '$row');
        expect(support.reason, contains('discriminating device run'));
      }
    }
  });

  test('an unknown Android GPU family and an unknown backend stay refused', () {
    expect(
      liteRtLmStructuredOutputSupport(
        abi: 'android_arm64',
        backend: PreferredBackend.gpu,
      ).isSupported,
      isFalse,
    );
    expect(
      liteRtLmStructuredOutputSupport(
        abi: 'macos_arm64',
        backend: null,
      ).isSupported,
      isFalse,
    );
  });

  test('only LLGuidance CreateConstraint failures become schema refusals', () {
    const schema = '{"type":"string"}';
    expect(
      liteRtLmConstraintFailure(
        schema,
        'Failed to create LLGuidance constraint: unsupported schema',
      ),
      isA<ResponseFormatUnsupportedException>(),
    );
    expect(
      liteRtLmConstraintFailure(
        schema,
        'INTERNAL: Failed to create LLGuidance constraint: incompatible types',
      ),
      isA<ResponseFormatUnsupportedException>(),
    );
    expect(
      liteRtLmConstraintFailure(null, 'Failed to create LLGuidance constraint'),
      isNull,
    );
    expect(
      liteRtLmConstraintFailure(schema, 'INTERNAL: decode failed'),
      isNull,
    );
  });

  test(
    'every rebuild and send path keeps the fixed schema (mutation guard)',
    () {
      final source = File(
        'lib/src/ffi/litert_lm_client.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final model = File(
        'lib/src/ffi/ffi_inference_model.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');

      expect(
        RegExp(
          r'createConversationHandle\([\s\S]*?jsonSchema: jsonSchema,',
        ).allMatches(model),
        hasLength(1),
        reason: 'the native open/reopen closure must carry the schema',
      );
      expect(
        model,
        contains('reopen: (messagesJson) => open(messagesJson: messagesJson)'),
        reason: 'native recovery must reuse the schema-bearing open closure',
      );
      expect(
        model,
        contains('jsonSchema: jsonSchema,\n      ))'),
        reason: 'the virtual handle must pass its schema on every turn',
      );
      expect(
        RegExp(
          r'_createRawConversation\([\s\S]*?jsonSchema: jsonSchema,',
        ).allMatches(source),
        hasLength(3),
        reason: 'initial native creation and virtual rebuild both need it',
      );
      expect(
        source,
        contains(
          'litert_lm_conversation_config_set_constraint_provider(\n'
          '              convConfig,',
        ),
        reason: 'removing the provider setter must fail this test',
      );
      expect(
        source,
        contains('jsonSchema: jsonSchema,\n            );'),
        reason: 'the virtual send must apply its schema every turn',
      );
      expect(
        source,
        contains('litert_lm_conversation_optional_args_set_constraint('),
        reason: 'removing the per-send constraint must fail this test',
      );
    },
  );

  test('the loaded model reports the support supplied by its engine', () {
    const support = StructuredOutputSupport(keywords: ResponseFormat.dialect);
    final model = FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      structuredOutput: support,
      onClose: () {},
    );

    expect(model.engineStructuredOutputSupport, same(support));
  });

  test('a model loaded with a thinking budget refuses formats', () {
    final model = FfiInferenceModel(
      ffiClient: _BudgetClient(),
      maxTokens: 1024,
      modelType: ModelType.gemma4,
      activeBackend: PreferredBackend.cpu,
      structuredOutput: const StructuredOutputSupport(
        keywords: ResponseFormat.dialect,
      ),
      onClose: () {},
    );

    expect(
      model.refusalFor(ResponseFormat.jsonObject()),
      isA<ResponseFormatUnsupportedException>().having(
        (error) => error.message,
        'message',
        contains('thinkingTokenBudget'),
      ),
    );
  });
}

class _BudgetClient extends LiteRtLmFfiClient {
  @override
  int? get thinkingTokenBudget => 64;
}
