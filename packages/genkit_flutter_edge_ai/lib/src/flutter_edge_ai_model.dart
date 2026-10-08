import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'backend_parse.dart';
import 'converters/request_converter.dart';
import 'converters/response_converter.dart';
import 'converters/tool_converter.dart';
import 'flutter_edge_ai_options.dart';
import 'flutter_edge_ai_runtime.dart';
import 'tool_choice_parse.dart';

/// Capabilities a flutter_edge_ai model advertises to Genkit. Shared by the
/// plugin's `list()` metadata AND the resolved [Model]'s `metadata` so the two
/// never drift (the resolved action previously carried no metadata, leaving its
/// supports empty at generate time). `constrained: false` — on-device Gemma has
/// no native schema-constrained decoder. Genkit never adds the schema to the
/// prompt by itself; the caller opts in with
/// `use: [simulateConstrainedGeneration()]`. We return the raw model text and
/// the framework's `extractJson` populates `response.output`.
const Map<String, dynamic> kFlutterEdgeAiModelSupports = {
  'multiturn': true,
  'media': true,
  'tools': true,
  'toolChoice': true,
  'systemRole': true,
  'constrained': false,
  'output': ['text', 'json'],
};

/// Creates a Genkit [Model] action backed by flutter_edge_ai inference.
///
/// Each call to the model's `fn`:
/// 1. Extracts options from `request.config`
/// 2. Gets (or reuses cached) [gemma.InferenceModel] via [runtime]
/// 3. Creates an [gemma.InferenceChat] session
/// 4. Converts Genkit messages → flutter_edge_ai messages
/// 5. Generates response (streaming or non-streaming)
/// 6. Converts response back to Genkit format
Model createFlutterEdgeAiModel({
  required String name,
  required gemma.ModelType modelType,
  required gemma.ModelFileType fileType,
  required FlutterEdgeAiRuntime runtime,
}) {
  // Cache the inference model to avoid recreating on every call.
  gemma.InferenceModel? cachedModel;
  int? cachedMaxTokens;
  bool? cachedSupportImage;
  bool? cachedSupportAudio;
  bool? cachedEnableSpeculativeDecoding;
  gemma.PreferredBackend? cachedPreferredBackend;
  gemma.PreferredBackend? cachedPreferredVisionBackend;
  gemma.PreferredBackend? cachedPreferredAudioBackend;

  // Future-chain lock: each caller awaits the previous one, ensuring
  // only one generation runs at a time against the native model.
  Future<void> lock = Future.value();

  return Model(
    name: name,
    metadata: {
      'model': {'supports': kFlutterEdgeAiModelSupports},
    },
    fn: (request, context) async {
      final prev = lock;
      final completer = Completer<void>();
      lock = completer.future;

      await prev;

      try {
        return await _executeGeneration(
          request: request,
          context: context,
          modelType: modelType,
          runtime: runtime,
          cachedModel: cachedModel,
          cachedMaxTokens: cachedMaxTokens,
          cachedSupportImage: cachedSupportImage,
          cachedSupportAudio: cachedSupportAudio,
          cachedEnableSpeculativeDecoding: cachedEnableSpeculativeDecoding,
          cachedPreferredBackend: cachedPreferredBackend,
          cachedPreferredVisionBackend: cachedPreferredVisionBackend,
          cachedPreferredAudioBackend: cachedPreferredAudioBackend,
          onModelCached:
              (
                model,
                maxTokens,
                supportImage,
                supportAudio,
                enableSpeculativeDecoding,
                preferredBackend,
                preferredVisionBackend,
                preferredAudioBackend,
              ) {
                cachedModel = model;
                cachedMaxTokens = maxTokens;
                cachedSupportImage = supportImage;
                cachedSupportAudio = supportAudio;
                cachedEnableSpeculativeDecoding = enableSpeculativeDecoding;
                cachedPreferredBackend = preferredBackend;
                cachedPreferredVisionBackend = preferredVisionBackend;
                cachedPreferredAudioBackend = preferredAudioBackend;
              },
        );
      } finally {
        completer.complete();
      }
    },
  );
}

/// The options the schema declares as integers. Their generated getters read
/// any JSON number and truncate it (`(json as num?)?.toInt()`), so
/// `maxTokens: 0.9` would reach the runtime as 0.
final Set<String> _integerOptions = {
  for (final MapEntry(:key, :value)
      in ((FlutterEdgeAiModelOptions.$schema.jsonSchema()['properties']
                  as Map<String, Object?>?) ??
              const <String, Object?>{})
          .entries)
    if (value case {'type': 'integer'}) key,
};

/// Rejects a non-integral number for an integer option; `1024.0` passes.
void _rejectFractionalIntegers(Map<String, dynamic> config) {
  for (final key in _integerOptions) {
    if (config[key] case final num value when value != value.roundToDouble()) {
      throw FormatException('$key must be an integer, got $value');
    }
  }
}

/// Executes the generation logic, extracted for readability.
Future<ModelResponse> _executeGeneration({
  required ModelRequest request,
  required ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
  required gemma.ModelType modelType,
  required FlutterEdgeAiRuntime runtime,
  required gemma.InferenceModel? cachedModel,
  required int? cachedMaxTokens,
  required bool? cachedSupportImage,
  required bool? cachedSupportAudio,
  required bool? cachedEnableSpeculativeDecoding,
  required gemma.PreferredBackend? cachedPreferredBackend,
  required gemma.PreferredBackend? cachedPreferredVisionBackend,
  required gemma.PreferredBackend? cachedPreferredAudioBackend,
  required void Function(
    gemma.InferenceModel,
    int,
    bool,
    bool,
    bool?,
    gemma.PreferredBackend?,
    gemma.PreferredBackend?,
    gemma.PreferredBackend?,
  )
  onModelCached,
}) async {
  // The request may have waited on the previous generation's lock; a caller
  // that gave up meanwhile should not pay for loading a model.
  context.cancel?.throwIfCancelled();

  // Parse config from the untyped Map. Every option is read inside the try:
  // the generated getters cast lazily, so a value of the wrong type ('0.7' for
  // temperature) throws here. Read later, it escaped as a TypeError, which a
  // hybrid router treats as transient and quietly hands to the next branch.
  final configMap = request.config;
  final int maxTokens;
  final double temperature;
  final int topK;
  final double? topP;
  final int randomSeed;
  final bool supportImage;
  final bool supportAudio;
  final bool enableThinking;
  final bool? enableSpeculativeDecoding;
  final String? configToolChoice;
  final String? configSystemInstruction;
  final int? maxFunctionBufferLength;
  final String? configPreferredBackend;
  final String? configPreferredVisionBackend;
  final String? configPreferredAudioBackend;
  try {
    if (configMap != null) _rejectFractionalIntegers(configMap);
    final config = configMap != null
        ? FlutterEdgeAiModelOptions.fromJson(configMap)
        : null;
    maxTokens = config?.maxTokens ?? 1024;
    temperature = config?.temperature ?? 0.8;
    topK = config?.topK ?? 1;
    topP = config?.topP;
    randomSeed = config?.randomSeed ?? 1;
    supportImage = config?.supportImage ?? false;
    supportAudio = config?.supportAudio ?? false;
    enableThinking = config?.enableThinking ?? false;
    enableSpeculativeDecoding = config?.enableSpeculativeDecoding;
    configToolChoice = config?.toolChoice;
    configSystemInstruction = config?.systemInstruction;
    maxFunctionBufferLength = config?.maxFunctionBufferLength;
    configPreferredBackend = config?.preferredBackend;
    configPreferredVisionBackend = config?.preferredVisionBackend;
    configPreferredAudioBackend = config?.preferredAudioBackend;
  } catch (e) {
    throw GenkitException(
      'Invalid model config: $e',
      status: StatusCode.invalidArgument,
    );
  }

  // Prefer the native top-level request.toolChoice (Genkit's standard
  // field) over the legacy config.toolChoice custom option. Fails loud on an
  // unrecognized value (see parseToolChoice) rather than silently defaulting
  // to auto — a 'none' typo must not quietly re-enable tools.
  final gemmaToolChoice = parseToolChoice(
    request.toolChoice?.value ?? configToolChoice,
  );
  final systemInstruction =
      configSystemInstruction ?? extractSystemInstruction(request.messages);
  final preferredBackend = parsePreferredBackend(
    configPreferredBackend,
    field: 'preferredBackend',
  );
  final preferredVisionBackend = parsePreferredBackend(
    configPreferredVisionBackend,
    field: 'preferredVisionBackend',
  );
  final preferredAudioBackend = parsePreferredBackend(
    configPreferredAudioBackend,
    field: 'preferredAudioBackend',
  );

  // Get or create InferenceModel (cached if params match).
  final needsNewModel =
      cachedModel == null ||
      cachedMaxTokens != maxTokens ||
      cachedSupportImage != supportImage ||
      cachedSupportAudio != supportAudio ||
      cachedEnableSpeculativeDecoding != enableSpeculativeDecoding ||
      cachedPreferredBackend != preferredBackend ||
      cachedPreferredVisionBackend != preferredVisionBackend ||
      cachedPreferredAudioBackend != preferredAudioBackend;

  gemma.InferenceModel model;
  if (needsNewModel) {
    model = await runtime.getActiveModel(
      maxTokens: maxTokens,
      supportImage: supportImage,
      supportAudio: supportAudio,
      enableSpeculativeDecoding: enableSpeculativeDecoding,
      preferredBackend: preferredBackend,
      preferredVisionBackend: preferredVisionBackend,
      preferredAudioBackend: preferredAudioBackend,
    );
    onModelCached(
      model,
      maxTokens,
      supportImage,
      supportAudio,
      enableSpeculativeDecoding,
      preferredBackend,
      preferredVisionBackend,
      preferredAudioBackend,
    );
  } else {
    model = cachedModel;
  }

  // Convert tools.
  final gemmaTools = convertTools(request.tools);
  final supportsFunctionCalls = gemmaTools.isNotEmpty;

  // Create chat session.
  final chat = await model.createChat(
    temperature: temperature,
    randomSeed: randomSeed,
    topK: topK,
    topP: topP,
    supportImage: supportImage,
    supportAudio: supportAudio,
    tools: gemmaTools,
    supportsFunctionCalls: supportsFunctionCalls,
    enableThinking: enableThinking,
    modelType: modelType,
    toolChoice: gemmaToolChoice,
    systemInstruction: systemInstruction,
    maxFunctionBufferLength: maxFunctionBufferLength,
  );

  // Convert and add messages.
  final gemmaMessages = await convertMessages(request.messages);
  if (gemmaMessages.isEmpty) {
    throw GenkitException(
      'No convertible messages in request. System messages alone are not '
      'sufficient — at least one user or model message is required.',
      status: StatusCode.invalidArgument,
    );
  }
  for (final msg in gemmaMessages) {
    await chat.addQueryChunk(msg);
  }

  // Generate response. Cancelling the caller's token stops native decoding,
  // and the turn then ends as a CancelledException, which genkit reports as an
  // aborted response instead of a complete-looking truncated answer.
  final cancel = context.cancel;
  cancel?.throwIfCancelled();
  // Completes once a requested stop has landed, with its error if it failed.
  // The handler is attached at once, so a failing stop is never an unhandled
  // async error.
  Future<(Object, StackTrace)?>? stopped;
  final detach = cancel?.onCancel(() {
    stopped = chat.stopGeneration().then<(Object, StackTrace)?>(
      (_) => null,
      onError: (Object error, StackTrace stack) => (error, stack),
    );
  });
  try {
    final stopwatch = Stopwatch()..start();
    final response = context.streamingRequested
        ? await _generateStreaming(chat, context.sendChunk, stopwatch)
        : await _generateBlocking(chat, stopwatch);
    // A stop still in flight must land before the caller releases the lock:
    // otherwise it reaches the shared native model during the next request.
    if (await stopped case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
    cancel?.throwIfCancelled();
    return response;
  } catch (_) {
    // The same wait on the failure path; the generation's own error is the
    // one reported.
    await stopped;
    rethrow;
  } finally {
    detach?.call();
  }
}

/// Generates a blocking (non-streaming) response.
Future<ModelResponse> _generateBlocking(
  gemma.InferenceChat chat,
  Stopwatch stopwatch,
) async {
  final response = await chat.generateChatResponse();
  final latencyMs = stopwatch.elapsedMilliseconds.toDouble();

  switch (response) {
    case gemma.TextResponse(:final token):
      return convertFinalResponse(token, latencyMs: latencyMs);
    case gemma.FunctionCallResponse(:final name, :final args):
      return convertFinalResponse(
        '',
        functionCalls: [gemma.FunctionCallResponse(name: name, args: args)],
        latencyMs: latencyMs,
      );
    case gemma.ParallelFunctionCallResponse(:final calls):
      return convertFinalResponse(
        '',
        functionCalls: calls,
        latencyMs: latencyMs,
      );
    case gemma.ThinkingResponse(:final content):
      return convertFinalResponse(
        '',
        reasoningText: content,
        latencyMs: latencyMs,
      );
  }
}

/// Generates a streaming response, sending chunks via [sendChunk].
Future<ModelResponse> _generateStreaming(
  gemma.InferenceChat chat,
  void Function(ModelResponseChunk) sendChunk,
  Stopwatch stopwatch,
) async {
  final fullText = StringBuffer();
  final reasoningText = StringBuffer();
  final functionCalls = <gemma.FunctionCallResponse>[];

  await for (final chunk in chat.generateChatResponseAsync()) {
    sendChunk(convertStreamChunk(chunk));

    switch (chunk) {
      case gemma.TextResponse(:final token):
        fullText.write(token);
      case gemma.FunctionCallResponse(:final name, :final args):
        functionCalls.add(gemma.FunctionCallResponse(name: name, args: args));
      case gemma.ParallelFunctionCallResponse(:final calls):
        functionCalls.addAll(calls);
      case gemma.ThinkingResponse(:final content):
        reasoningText.write(content);
    }
  }

  return convertFinalResponse(
    fullText.toString(),
    functionCalls: functionCalls.isNotEmpty ? functionCalls : null,
    reasoningText: reasoningText.isNotEmpty ? reasoningText.toString() : null,
    latencyMs: stopwatch.elapsedMilliseconds.toDouble(),
  );
}
