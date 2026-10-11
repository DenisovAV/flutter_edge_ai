import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/genkit.dart'
    show SimulateConstrainedGenerationMiddleware;
import 'package:genkit/plugin.dart';

import 'backend_parse.dart';
import 'converters/request_converter.dart';
import 'converters/response_converter.dart';
import 'converters/tool_converter.dart';
import 'flutter_edge_ai_options.dart';
import 'flutter_edge_ai_runtime.dart';
import 'model_options_parse.dart';
import 'runtime_errors.dart';
import 'tool_choice_parse.dart';

/// Capabilities a flutter_edge_ai model advertises to Genkit, for a model
/// configured with tools and media on (the defaults). See
/// [flutterEdgeAiModelSupports].
const Map<String, dynamic> kFlutterEdgeAiModelSupports = {
  'multiturn': true,
  'media': true,
  'tools': true,
  'toolChoice': true,
  'systemRole': true,
  'constrained': false,
  'output': ['text', 'json'],
};

/// Capabilities a flutter_edge_ai model advertises to Genkit. Shared by the
/// plugin's `list()` metadata AND the resolved [Model]'s `metadata` so the two
/// never drift. [tools] and [media] come from the model's configuration; a
/// request that needs one the model was configured without is rejected.
///
/// `constrained: false`: no engine has a schema-constrained decoder. A request
/// that asks for `constrained: true` output gets the schema written into the
/// prompt, as Genkit's `simulateConstrainedGeneration()` middleware does, and
/// Genkit extracts the JSON from the reply. The reply is not validated against
/// the schema.
Map<String, dynamic> flutterEdgeAiModelSupports({
  bool tools = true,
  bool media = true,
}) => {
  ...kFlutterEdgeAiModelSupports,
  'tools': tools,
  'toolChoice': tools,
  'media': media,
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
///
/// [supportsTools] and [supportsMedia] declare what the installed model can
/// take; a request with tools or media it cannot take is an INVALID_ARGUMENT
/// instead of reaching a model that would ignore them.
Model createFlutterEdgeAiModel({
  required String name,
  required gemma.ModelType modelType,
  required gemma.ModelFileType fileType,
  required FlutterEdgeAiRuntime runtime,
  bool supportsTools = true,
  bool supportsMedia = true,
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

  Future<ModelResponse> run(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
  ) async {
    final prev = lock;
    final completer = Completer<void>();
    lock = completer.future;

    // A request cancelled while queued returns at once, but its place in the
    // chain is held until the turn ahead of it ends, so nothing queued
    // behind it overtakes the generation in progress.
    final cancel = context.cancel;
    if (cancel == null) {
      await prev;
    } else {
      // onCancel, not whenCancelled: a token reused for a whole chat would
      // keep one listener per call on a future that can never be detached.
      final turn = Completer<void>();
      final detachWait = cancel.onCancel(() {
        if (!turn.isCompleted) turn.complete();
      });
      unawaited(
        prev.then((_) {
          if (!turn.isCompleted) turn.complete();
        }),
      );
      await turn.future;
      detachWait();
      if (cancel.isCancelled) {
        unawaited(prev.whenComplete(completer.complete));
        cancel.throwIfCancelled();
      }
    }

    try {
      return await _executeGeneration(
        request: request,
        context: context,
        modelType: modelType,
        runtime: runtime,
        supportsTools: supportsTools,
        supportsMedia: supportsMedia,
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
  }

  return Model<FlutterEdgeAiModelOptions>(
    name: name,
    customOptions: FlutterEdgeAiModelOptions.$schema,
    metadata: {
      'model': {
        'supports': flutterEdgeAiModelSupports(
          tools: supportsTools,
          media: supportsMedia,
        ),
      },
    },
    fn: (request, context) {
      final output = request.output;
      // No engine can constrain decoding to a schema, so a request that asks
      // for it gets the schema in the prompt, the way Genkit's
      // simulateConstrainedGeneration() middleware writes it. When the caller
      // already added that middleware, it has set `constrained` to false and
      // this does nothing.
      if (output?.constrained == true && output?.schema != null) {
        return SimulateConstrainedGenerationMiddleware().model(
          request,
          context,
          run,
        );
      }
      return run(request, context);
    },
  );
}

/// Executes the generation logic, extracted for readability.
Future<ModelResponse> _executeGeneration({
  required ModelRequest request,
  required ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
  required gemma.ModelType modelType,
  required FlutterEdgeAiRuntime runtime,
  required bool supportsTools,
  required bool supportsMedia,
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

  // Validated before a model loads: a bad value is the caller's error, not a
  // transient one a hybrid router would hand to its next branch.
  final config = await parseModelOptions(request.config);
  final maxTokens = config?.maxTokens ?? 1024;
  final maxOutputTokens = config?.maxOutputTokens;
  // Unset sampling stays unset: flutter_edge_ai fills it from the model's own
  // sampler or its family's defaults.
  final temperature = config?.temperature;
  final topK = config?.topK;
  final topP = config?.topP;
  final randomSeed = config?.randomSeed;
  final supportImage = config?.supportImage ?? false;
  final supportAudio = config?.supportAudio ?? false;
  final enableThinking = config?.enableThinking ?? false;
  final enableSpeculativeDecoding = config?.enableSpeculativeDecoding;
  final configToolChoice = config?.toolChoice;
  final configSystemInstruction = config?.systemInstruction;
  final maxFunctionBufferLength = config?.maxFunctionBufferLength;
  final configPreferredBackend = config?.preferredBackend;
  final configPreferredVisionBackend = config?.preferredVisionBackend;
  final configPreferredAudioBackend = config?.preferredAudioBackend;

  if (!supportsTools && (request.tools?.isNotEmpty ?? false)) {
    throw GenkitException(
      'This model is configured without tools (supportsTools: false), but '
      'the request declares ${request.tools!.length}.',
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
  final systemInstruction = configSystemInstruction == null
      ? extractSystemInstruction(request.messages)
      : _withOutputInstructions(configSystemInstruction, request.messages);
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

  // Converted before a model loads: a part the model cannot take, or media
  // the configuration does not enable, fails without loading anything.
  final gemmaMessages = await convertMessages(request.messages);
  // A media download can take a while; a caller who gave up meanwhile should
  // not pay for loading the model.
  context.cancel?.throwIfCancelled();
  if (gemmaMessages.isEmpty) {
    throw GenkitException(
      'No convertible messages in request. System messages alone are not '
      'sufficient — at least one user or model message is required.',
      status: StatusCode.invalidArgument,
    );
  }
  var inputImages = 0;
  var inputAudioFiles = 0;
  for (final message in gemmaMessages) {
    inputImages += message.images.length + (message.imageBytes == null ? 0 : 1);
    if (message.audioBytes != null) inputAudioFiles++;
  }
  if ((inputImages > 0 || inputAudioFiles > 0) && !supportsMedia) {
    throw GenkitException(
      'This model is configured without media (supportsMedia: false), but '
      'the request carries an image or audio.',
      status: StatusCode.invalidArgument,
    );
  }
  if (inputImages > 0 && !supportImage) {
    throw GenkitException(
      'The request carries an image, but the config does not set '
      'supportImage: true, so the model would never see it.',
      status: StatusCode.invalidArgument,
    );
  }
  if (inputAudioFiles > 0 && !supportAudio) {
    throw GenkitException(
      'The request carries audio, but the config does not set '
      'supportAudio: true, so the model would never hear it.',
      status: StatusCode.invalidArgument,
    );
  }

  gemma.InferenceModel model;
  if (needsNewModel) {
    model = await withRuntimeErrors(
      'Could not load the on-device model',
      () => runtime.getActiveModel(
        maxTokens: maxTokens,
        supportImage: supportImage,
        supportAudio: supportAudio,
        enableSpeculativeDecoding: enableSpeculativeDecoding,
        preferredBackend: preferredBackend,
        preferredVisionBackend: preferredVisionBackend,
        preferredAudioBackend: preferredAudioBackend,
      ),
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
  final chat = await withRuntimeErrors(
    'Could not open a chat on the on-device model',
    () => model.createChat(
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
      maxOutputTokens: maxOutputTokens,
    ),
  );

  for (final msg in gemmaMessages) {
    await chat.addQueryChunk(msg);
  }

  // Generate response. Cancelling the caller's token stops native decoding,
  // and the turn then ends as a CancelledException, which genkit reports as an
  // aborted response instead of a complete-looking truncated answer.
  final cancel = context.cancel;
  cancel?.throwIfCancelled();
  // Completes once a requested stop has landed, with its error if it failed.
  // Future.sync and an immediate handler: a failing stop, synchronous or not,
  // is never an unhandled error.
  Future<(Object, StackTrace)?>? stopped;
  void stop() {
    stopped ??= Future.sync(chat.stopGeneration).then<(Object, StackTrace)?>(
      (_) => null,
      onError: (Object error, StackTrace stack) => (error, stack),
    );
  }

  final detach = cancel?.onCancel(stop);
  ModelResponse? response;
  Object? failure;
  StackTrace? failureStack;
  try {
    final stopwatch = Stopwatch()..start();
    response = context.streamingRequested
        ? await _generateStreaming(
            chat,
            context.sendChunk,
            stopwatch,
            cancel: cancel,
            onSendChunkFailure: stop,
          )
        : await _generateBlocking(chat, stopwatch);
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
  }
  // Detach before the first await below: from here on no stop can start, so
  // the one awaited next is the last. It must land before the caller releases
  // the lock, or it reaches the shared native model during the next request.
  detach?.call();
  final stopFailure = await stopped;
  if (failure != null) {
    // The generation's own error is the one reported. A stop that failed as
    // well goes into it: the engine may still be decoding, which the caller
    // needs to know, and a log line is invisible in a release build.
    if (stopFailure case (final stopError, _)) {
      throw GenkitException(
        '$failure; stopping the generation also failed: $stopError. The '
        'on-device engine may still be decoding.',
        status: failure is GenkitException ? failure.status : null,
        cause: failure,
        stackTrace: failureStack,
      );
    }
    Error.throwWithStackTrace(failure, failureStack!);
  }
  if (stopFailure case (final error, final stack)) {
    Error.throwWithStackTrace(error, stack);
  }
  cancel?.throwIfCancelled();
  return response!.withUsage(
    convertUsage(
      _sessionMetrics(chat),
      inputImages: inputImages,
      inputAudioFiles: inputAudioFiles,
    ),
  );
}

/// [systemInstruction] with the output-schema instructions Genkit's
/// constrained-output simulation wrote into the request's system messages. A
/// configured system instruction replaces those messages, and without this
/// the schema would go with them.
String _withOutputInstructions(
  String systemInstruction,
  List<Message> messages,
) {
  final instructions = [
    for (final message in messages)
      if (message.role == Role.system)
        for (final part in message.content)
          if (part.isText && part.metadata?['purpose'] == 'output') part.text!,
  ];
  if (instructions.isEmpty) return systemInstruction;
  return [systemInstruction, ...instructions].join('\n');
}

/// The chat's token counts and speed for the generation that just ended, or
/// null where the engine cannot report them.
gemma.SessionMetrics? _sessionMetrics(gemma.InferenceChat chat) {
  try {
    return chat.session.getSessionMetrics();
  } on Object {
    return null;
  }
}

extension on ModelResponse {
  /// This response with [usage], when there is any.
  ModelResponse withUsage(GenerationUsage? usage) {
    if (usage == null) return this;
    return ModelResponse(
      finishReason: finishReason,
      finishMessage: finishMessage,
      message: message,
      latencyMs: latencyMs,
      usage: usage,
      custom: custom,
    );
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
///
/// A cancel stops forwarding at once: leaving the loop also cancels the stream,
/// which stops native decoding on the engines that observe it. If [sendChunk]
/// itself throws, [onSendChunkFailure] stops the generation first, since an
/// engine such as MediaPipe keeps decoding after its stream is cancelled.
Future<ModelResponse> _generateStreaming(
  gemma.InferenceChat chat,
  void Function(ModelResponseChunk) sendChunk,
  Stopwatch stopwatch, {
  required CancellationToken? cancel,
  required void Function() onSendChunkFailure,
}) async {
  final fullText = StringBuffer();
  final reasoningText = StringBuffer();
  final functionCalls = <gemma.FunctionCallResponse>[];

  await for (final chunk in chat.generateChatResponseAsync()) {
    if (cancel?.isCancelled ?? false) break;
    try {
      sendChunk(
        convertStreamChunk(chunk, firstToolCallIndex: functionCalls.length),
      );
    } catch (_) {
      onSendChunkFailure();
      rethrow;
    }

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
