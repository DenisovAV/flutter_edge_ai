import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter_edge_ai/engine.dart'
    show
        JsonSchemaResponseFormat,
        ResponseFormatUnsupportedException,
        StructuredDelivery,
        StructuredOutputSupport;

/// The schema keywords the built-in OS models enforce, the same on every
/// platform that takes a schema: flutter_local_ai's schema subset
/// (`validateGenerationSchema`), which Apple's `GenerationSchema` builder
/// mirrors. `additionalProperties`, `const` and the numeric and length bounds
/// are outside it, so core refuses them with their path.
const builtInSchemaKeywords = {
  'type',
  'properties',
  'required',
  'items',
  'minItems',
  'maxItems',
  'enum',
};

/// The OS model behind this build, as far as structured output goes.
enum BuiltInPlatform { apple, appleIos, chrome, windows, android, none }

/// The platform this process runs on.
BuiltInPlatform currentBuiltInPlatform() {
  if (kIsWeb) return BuiltInPlatform.chrome;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS => BuiltInPlatform.apple,
    TargetPlatform.iOS => BuiltInPlatform.appleIos,
    TargetPlatform.windows => BuiltInPlatform.windows,
    TargetPlatform.android => BuiltInPlatform.android,
    TargetPlatform.linux || TargetPlatform.fuchsia => BuiltInPlatform.none,
  };
}

/// The platforms whose discriminating run has passed
/// (`example/integration_test/builtin_ai_structured_test.dart`). A platform
/// is added here only after that run, on its own device. None yet: macOS 27
/// reported Apple Intelligence as still downloading on 2026-11-04.
const _verifiedPlatforms = <BuiltInPlatform>{};

/// Replaces [_verifiedPlatforms] in tests, so the structured path can be
/// driven on a fake host before any platform is enabled.
@visibleForTesting
Set<BuiltInPlatform>? debugVerifiedBuiltInPlatforms;

const _structuredSupport = StructuredOutputSupport(
  keywords: builtInSchemaKeywords,
  // flutter_local_ai answers a schema with one complete value; it has no
  // streamed structured call.
  delivery: StructuredDelivery.buffered,
);

/// What a built-in model enforces on [platform].
///
/// Apple, Chrome and Windows each have the whole path behind them: the
/// schema is sent (`getStructuredResponse`) and the turn's end is reported.
/// Each is refused, with a reason naming the missing run, until it is in
/// [_verifiedPlatforms]. Android never takes one.
///
/// No availability check is needed on Apple: a model exists only when
/// Foundation Models is available, which needs iOS/macOS 26, the release that
/// added `GenerationSchema`.
StructuredOutputSupport builtInStructuredOutputSupport(
  BuiltInPlatform platform,
) {
  final verified = debugVerifiedBuiltInPlatforms ?? _verifiedPlatforms;
  return switch (platform) {
    BuiltInPlatform.android => const StructuredOutputSupport.none(
      'Gemini Nano through ML Kit GenAI takes a response schema only as a '
      'compile-time type; flutter_local_ai does not bridge it and reports no '
      'structured output on Android.',
    ),
    BuiltInPlatform.none => const StructuredOutputSupport.none(
      'There is no built-in OS model on this platform.',
    ),
    _ when verified.contains(platform) => _structuredSupport,
    BuiltInPlatform.apple => const StructuredOutputSupport.none(
      'Apple Foundation Models on macOS has not been run with a response '
      'format yet; it is enabled after that run.',
    ),
    BuiltInPlatform.appleIos => const StructuredOutputSupport.none(
      'Apple Foundation Models on iOS has not been run with a response format '
      'yet; it is enabled after its device run.',
    ),
    BuiltInPlatform.chrome => const StructuredOutputSupport.none(
      "Chrome's Prompt API (responseConstraint) has not been run with a "
      'response format yet; it is enabled after that run.',
    ),
    BuiltInPlatform.windows => const StructuredOutputSupport.none(
      'Phi Silica (GenerateStructuredJsonResponseAsync) has not been run with '
      'a response format yet; it is enabled after its device run.',
    ),
  };
}

/// Why [format] is refused on [platform] beyond its keywords, or null.
///
/// Called by core after the keyword check, so [format] uses only
/// [builtInSchemaKeywords] and annotations. Refused everywhere, because
/// flutter_local_ai rejects them before the platform sees the schema: an
/// `enum` that is not all strings, or that comes with a `type` other than
/// `string` (only string choices exist there); a `null` type; an array with
/// no `items`. On Apple also an object with no properties: its
/// `GenerationSchema` can only produce `{}`.
ResponseFormatUnsupportedException? builtInSchemaRefusal(
  JsonSchemaResponseFormat format,
  BuiltInPlatform platform,
) => _refusal(
  format.schema,
  '',
  apple:
      platform == BuiltInPlatform.apple || platform == BuiltInPlatform.appleIos,
);

ResponseFormatUnsupportedException? _refusal(
  Map<String, Object?> schema,
  String path, {
  required bool apple,
}) {
  final type = schema['type'];
  final choices = schema['enum'];
  if (choices is List) {
    if (choices.any((choice) => choice is! String)) {
      return ResponseFormatUnsupportedException(
        'Built-in OS models take only string enum values.',
        schemaPath: '$path/enum',
      );
    }
    if (type != null && type != 'string') {
      return ResponseFormatUnsupportedException(
        'Built-in OS models take an enum only as string choices, not with '
        'type "$type".',
        schemaPath: '$path/type',
      );
    }
    // Like flutter_local_ai's validator, an enum is the whole constraint.
    return null;
  }
  switch (type) {
    case 'null':
      return ResponseFormatUnsupportedException(
        'Built-in OS models have no null type.',
        schemaPath: '$path/type',
      );
    case 'array':
      final items = schema['items'];
      if (items is! Map<String, Object?>) {
        return ResponseFormatUnsupportedException(
          'Built-in OS models need an items schema on an array.',
          schemaPath: _typePath(schema, path),
        );
      }
      return _refusal(items, '$path/items', apple: apple);
    case 'object' || null:
      final properties = schema['properties'];
      if (properties is! Map<String, Object?> || properties.isEmpty) {
        if (!apple) return null;
        return ResponseFormatUnsupportedException(
          'Apple Foundation Models can produce only {} for an object with no '
          'properties.',
          schemaPath: _typePath(schema, path),
        );
      }
      for (final MapEntry(:key, :value) in properties.entries) {
        final refused = _refusal(
          value! as Map<String, Object?>,
          '$path/properties/${_pointerToken(key)}',
          apple: apple,
        );
        if (refused != null) return refused;
      }
      return null;
    default:
      return null;
  }
}

/// Where a refusal of the subschema at [path] points: its `type`, or the
/// subschema itself when it declares none (null at the root: the whole
/// format).
String? _typePath(Map<String, Object?> schema, String path) =>
    schema.containsKey('type') ? '$path/type' : (path.isEmpty ? null : path);

/// [token] escaped for a JSON Pointer (RFC 6901).
String _pointerToken(String token) =>
    token.replaceAll('~', '~0').replaceAll('/', '~1');
