import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/genkit.dart'
    show SimulateConstrainedGenerationMiddleware;
import 'package:genkit/plugin.dart';

import 'converters/request_converter.dart';
import 'converters/response_converter.dart';
import 'converters/tool_converter.dart';
import 'flutter_edge_ai_options.dart';
import 'flutter_edge_ai_runtime.dart';
import 'model_options_parse.dart';
import 'model_slot.dart';
import 'runtime_errors.dart';
import 'schema_inline.dart';
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
/// `constrained: false`: whether a schema is enforced depends on the model
/// loaded at the time, so it is not promised. A request that asks for
/// `constrained: true` output gets the schema written into the prompt, as
/// Genkit's `simulateConstrainedGeneration()` middleware does. When the
/// request has no tools and no thinking, and the loaded model accepts the
/// schema (`InferenceModel.refusalFor`), it is also sent as the chat's
/// `responseFormat`: the engine enforces it and flutter_edge_ai checks the
/// reply. Otherwise Genkit extracts the JSON from the reply, which nothing
/// validates against the schema.
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
/// A request is prepared first, while the ones ahead of it run: its options
/// validated, its messages, media and tools converted. Then it takes its turn
/// on [slot], the on-device model that every configured name runs, and
/// generates. Without a [slot] the model gets one of its own.
///
/// [supportsTools] and [supportsMedia] declare what the installed model can
/// take; a request with tools or media it cannot take is UNIMPLEMENTED
/// instead of reaching a model that would ignore them.
Model createFlutterEdgeAiModel({
  required String name,
  required gemma.ModelType modelType,
  required gemma.ModelFileType fileType,
  required FlutterEdgeAiRuntime runtime,
  FlutterEdgeAiModelSlot? slot,
  bool supportsTools = true,
  bool supportsMedia = true,
}) {
  assert(
    slot == null || identical(slot.runtime, runtime),
    'The slot loads from another runtime than this model',
  );
  final modelSlot = slot ?? FlutterEdgeAiModelSlot(runtime);

  Future<ModelResponse> run(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> context, {
    gemma.JsonSchemaResponseFormat? responseFormat,
  }) async {
    // The place in the queue is taken on arrival, so requests reach the model
    // in the order they came.
    final turn = modelSlot.enqueue();
    try {
      final prepared = await _prepare(
        request,
        context.cancel,
        modelType: modelType,
        supportsTools: supportsTools,
        supportsMedia: supportsMedia,
        responseFormat: responseFormat,
      );
      await turn.start(context.cancel);
      return await _generate(prepared, modelSlot, context);
    } finally {
      turn.end();
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
      // A request that asks for constrained output gets the schema in the
      // prompt, the way Genkit's simulateConstrainedGeneration() middleware
      // writes it, since whether the model can enforce it is known only once
      // it is loaded. The schema also goes on as a responseFormat, which
      // _generate sends when the loaded model accepts it. When the caller
      // already added that middleware, it has set `constrained` to false and
      // this does nothing.
      if (output?.constrained == true && output?.schema != null) {
        final responseFormat = _responseFormatOf(output!);
        return SimulateConstrainedGenerationMiddleware().model(
          request,
          context,
          (request, context) =>
              run(request, context, responseFormat: responseFormat),
        );
      }
      return run(request, context);
    },
  );
}

/// [output]'s schema as a flutter_edge_ai format, or null when it cannot be
/// one: a format other than JSON, a schema whose references cannot be
/// inlined (see [inlineSchemaRefs]), or one outside
/// `gemma.ResponseFormat.dialect`'s rules (a type union, a boolean
/// subschema). Such a schema stays a prompt instruction only, as before.
gemma.JsonSchemaResponseFormat? _responseFormatOf(OutputConfig output) {
  final format = output.format;
  if (format != null && format != 'json') return null;
  final schema = inlineSchemaRefs(output.schema!);
  if (schema == null) return null;
  try {
    return gemma.ResponseFormat.jsonSchema(schema)
        as gemma.JsonSchemaResponseFormat;
  } on RangeError {
    // A bug, not a schema outside the dialect.
    rethrow;
  } on ArgumentError {
    return null;
  }
}

/// A request converted and checked, ready for the model.
class _PreparedRequest {
  _PreparedRequest({
    required this.load,
    required this.config,
    required this.modelType,
    required this.toolChoice,
    required this.systemInstruction,
    required this.tools,
    required this.messages,
    required this.inputImages,
    required this.inputAudioFiles,
    required this.responseFormat,
  });

  final ModelLoadParams load;
  final FlutterEdgeAiModelOptions? config;
  final gemma.ModelType modelType;
  final gemma.ToolChoice toolChoice;
  final String? systemInstruction;
  final List<gemma.Tool> tools;
  final List<gemma.Message> messages;
  final int inputImages;
  final int inputAudioFiles;

  /// The format to send when the loaded model accepts it; null when the
  /// request asks for none, or has tools or thinking, which flutter_edge_ai
  /// refuses beside a format.
  final gemma.JsonSchemaResponseFormat? responseFormat;
}

/// Validates and converts [request] without touching the model: a request
/// the model cannot take fails before anything loads, and the work runs
/// while earlier requests generate.
Future<_PreparedRequest> _prepare(
  ModelRequest request,
  CancellationToken? cancel, {
  required gemma.ModelType modelType,
  required bool supportsTools,
  required bool supportsMedia,
  required gemma.JsonSchemaResponseFormat? responseFormat,
}) async {
  cancel?.throwIfCancelled();

  // A bad value is the caller's error, not a transient one a hybrid router
  // would hand to its next branch.
  final config = await parseModelOptions(request.config);
  final supportImage = config?.supportImage ?? false;
  final supportAudio = config?.supportAudio ?? false;

  if (!supportsTools && (request.tools?.isNotEmpty ?? false)) {
    throw GenkitException(
      'This model is configured without tools (supportsTools: false), but '
      'the request declares ${request.tools!.length}.',
      status: StatusCode.unimplemented,
    );
  }
  if (!supportsMedia && (supportImage || supportAudio)) {
    throw GenkitException(
      'This model is configured without media (supportsMedia: false), but '
      'the config sets ${supportImage ? 'supportImage' : 'supportAudio'}.',
      status: StatusCode.unimplemented,
    );
  }

  // Prefer the native top-level request.toolChoice (Genkit's standard
  // field) over the legacy config.toolChoice custom option. Fails loud on an
  // unrecognized value (see parseToolChoice) rather than silently defaulting
  // to auto — a 'none' typo must not quietly re-enable tools.
  final toolChoice = parseToolChoice(
    request.toolChoice?.value ?? config?.toolChoice,
  );
  final configSystemInstruction = config?.systemInstruction;
  final systemInstruction = configSystemInstruction == null
      ? extractSystemInstruction(request.messages)
      : _withOutputInstructions(configSystemInstruction, request.messages);
  final load = loadParamsOf(config);
  final tools = convertTools(request.tools);

  final messages = await convertMessages(request.messages, cancel: cancel);
  if (messages.isEmpty) {
    throw GenkitException(
      'No convertible messages in request. System messages alone are not '
      'sufficient — at least one user or model message is required.',
      status: StatusCode.invalidArgument,
    );
  }
  // The converter puts a user message's images in `images` only.
  var inputImages = 0;
  var inputAudioFiles = 0;
  for (final message in messages) {
    inputImages += message.images.length;
    if (message.audioBytes != null) inputAudioFiles++;
  }
  if ((inputImages > 0 || inputAudioFiles > 0) && !supportsMedia) {
    throw GenkitException(
      'This model is configured without media (supportsMedia: false), but '
      'the request carries an image or audio.',
      status: StatusCode.unimplemented,
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

  return _PreparedRequest(
    load: load,
    config: config,
    modelType: modelType,
    toolChoice: toolChoice,
    systemInstruction: systemInstruction,
    tools: tools,
    messages: messages,
    inputImages: inputImages,
    inputAudioFiles: inputAudioFiles,
    responseFormat: tools.isEmpty && !(config?.enableThinking ?? false)
        ? responseFormat
        : null,
  );
}

/// Runs [prepared] on the model in [slot]. Call it only during the request's
/// turn: everything here reaches the shared native model.
Future<ModelResponse> _generate(
  _PreparedRequest prepared,
  FlutterEdgeAiModelSlot slot,
  ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
) async {
  final cancel = context.cancel;
  final config = prepared.config;

  final model = await slot.load(prepared.load);
  // Loading can take seconds; a caller who gave up meanwhile should not pay
  // for opening a chat as well.
  cancel?.throwIfCancelled();

  // The format goes to the model only when it can enforce it. A refusal
  // (most engines enforce none yet) is not an error: the schema is already
  // in the prompt, as it was before any engine could enforce one.
  final format = prepared.responseFormat;
  if (format != null &&
      await withRuntimeErrors(
        'Could not check the output schema against the on-device model',
        () async => model.refusalFor(format) == null,
      )) {
    gemma.InferenceChat? structured;
    try {
      structured = await withRuntimeErrors(
        'Could not open a chat on the on-device model',
        // A format is taken by openChat only. Tools and thinking are off:
        // _prepare dropped the format for a request with either.
        () => model.openChat(
          temperature: config?.temperature,
          randomSeed: config?.randomSeed,
          topK: config?.topK,
          topP: config?.topP,
          supportImage: prepared.load.supportImage,
          supportAudio: prepared.load.supportAudio,
          supportsFunctionCalls: false,
          modelType: prepared.modelType,
          // No tools to choose among; a `required` would be refused.
          toolChoice: gemma.ToolChoice.auto,
          systemInstruction: prepared.systemInstruction,
          maxFunctionBufferLength: config?.maxFunctionBufferLength,
          maxOutputTokens: config?.maxOutputTokens,
          responseFormat: format,
        ),
      );
    } on gemma.ResponseFormatUnsupportedException {
      // Refused after all: prompt-only, as a format refusalFor refuses.
      structured = null;
    }
    if (structured != null) {
      final tracker = _ChunkTracker();
      try {
        return await _runChat(structured, prepared, context, tracker);
      } on GenkitException catch (e) {
        // The engine refused the schema at the first send (LiteRT-LM's
        // constraint compiler): the same capability gap as a refusal
        // known up front, so the request runs again prompt-only, once,
        // with the chat already closed. Not after a chunk reached the
        // caller, nor after a failed close (its cause is then the wrapped
        // error, not the refusal).
        if (e.cause is! gemma.ResponseFormatUnsupportedException ||
            tracker.sent) {
          rethrow;
        }
        cancel?.throwIfCancelled();
      }
    }
  }

  final chat = await withRuntimeErrors(
    'Could not open a chat on the on-device model',
    // Unset sampling stays unset: flutter_edge_ai fills it from the model's
    // own sampler or its family's defaults.
    () => model.createChat(
      temperature: config?.temperature,
      randomSeed: config?.randomSeed,
      topK: config?.topK,
      topP: config?.topP,
      supportImage: prepared.load.supportImage,
      supportAudio: prepared.load.supportAudio,
      tools: prepared.tools,
      supportsFunctionCalls: prepared.tools.isNotEmpty,
      enableThinking: config?.enableThinking ?? false,
      modelType: prepared.modelType,
      toolChoice: prepared.toolChoice,
      systemInstruction: prepared.systemInstruction,
      maxFunctionBufferLength: config?.maxFunctionBufferLength,
      maxOutputTokens: config?.maxOutputTokens,
    ),
  );
  return _runChat(chat, prepared, context, _ChunkTracker());
}

/// Whether a chunk of the request's answer reached the caller.
final class _ChunkTracker {
  bool sent = false;
}

/// Runs [prepared] on [chat] and closes it. The chat is this request's
/// alone: it is closed before the request's turn ends, whatever happened, so
/// its session never outlives the request.
Future<ModelResponse> _runChat(
  gemma.InferenceChat chat,
  _PreparedRequest prepared,
  ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
  _ChunkTracker tracker,
) async {
  final ModelResponse response;
  try {
    response = await _respond(chat, prepared, context, tracker);
  } catch (failure, failureStack) {
    try {
      await chat.close();
    } catch (closeError, closeStack) {
      _reportFailedClose(closeError, closeStack);
      // A cancel stays a CancelledException, which callers catch by type.
      // (`rethrow` here would throw the close error.)
      if (failure is CancelledException) {
        Error.throwWithStackTrace(failure, failureStack);
      }
      // Otherwise the request's own error is the one reported, with the
      // failed close in it.
      throw GenkitException(
        '${failure is GenkitException ? failure.message : failure}; closing '
        'the chat also failed: $closeError',
        status: failure is GenkitException ? failure.status : null,
        cause: failure,
        stackTrace: failureStack,
      );
    }
    rethrow;
  }
  // The answer is complete: a failed close must not turn it into an error,
  // which a router could retry elsewhere with the same prompt.
  try {
    await chat.close();
  } catch (closeError, closeStack) {
    _reportFailedClose(closeError, closeStack);
  }
  return response;
}

/// Says that closing a request's chat threw. `print`, as core's
/// `ModelCloseGate` does: a release build drops debug logs, and release is
/// where a session left open gets debugged.
void _reportFailedClose(Object error, StackTrace stack) {
  // ignore: avoid_print
  print(
    '[genkit_flutter_edge_ai] WARNING: closing the chat of a request threw; '
    'its session may still be open: $error\n$stack',
  );
}

/// Sends [prepared] to [chat] and returns the model's answer, with the usage
/// its session reports. The caller closes [chat].
Future<ModelResponse> _respond(
  gemma.InferenceChat chat,
  _PreparedRequest prepared,
  ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
  _ChunkTracker tracker,
) async {
  final cancel = context.cancel;

  for (final message in prepared.messages) {
    await withRuntimeErrors(
      'Could not pass the request to the on-device model',
      () => chat.addQueryChunk(message),
    );
  }

  // Generate response. Cancelling the caller's token stops native decoding,
  // and the turn then ends as a CancelledException, which genkit reports as an
  // aborted response instead of a complete-looking truncated answer.
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
            (chunk) {
              tracker.sent = true;
              context.sendChunk(chunk);
            },
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
  // A structured turn the caller cancelled ends as an incomplete value,
  // stopped or, when the stop raced another end, cut by that one; either way
  // it is reported as the cancel, as a plain turn's stop is.
  if (failure is gemma.IncompleteStructuredOutputException &&
      (cancel?.isCancelled ?? false)) {
    failure = null;
    failureStack = null;
  } else if (failure case final gemma.StructuredOutputException error) {
    failure = structuredOutputError(
      'The on-device model gave no value of the output schema',
      error,
      failureStack!,
    );
  }
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
  final result = response!;
  final usage = convertUsage(
    _sessionMetrics(_sessionOf(chat)),
    inputImages: prepared.inputImages,
    inputAudioFiles: prepared.inputAudioFiles,
  );
  if (usage != null) result.usage = usage;
  return result;
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

/// The chat's current session, or null on an engine whose chat has none to
/// report from.
gemma.InferenceModelSession? _sessionOf(gemma.InferenceChat chat) {
  try {
    return chat.session;
  } on StateError {
    return null;
  }
}

/// [session]'s token counts and speed for the generation that just ended, or
/// null where the engine cannot report them: it does not implement them, or
/// the session has been closed since. A single-turn model's chat
/// (FunctionGemma) opens a fresh session once it has answered, so it reports
/// none. Any other failure is a bug and is thrown.
gemma.SessionMetrics? _sessionMetrics(gemma.InferenceModelSession? session) {
  if (session == null) return null;
  try {
    return session.getSessionMetrics();
  } on UnsupportedError {
    // UnimplementedError among them.
    return null;
  } on StateError {
    return null;
  } on Exception {
    return null;
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
    case final gemma.FunctionCallResponse call:
      return convertFinalResponse(
        '',
        functionCalls: [call],
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
      sendChunk(convertStreamChunk(chunk, earlierCalls: functionCalls));
    } catch (_) {
      onSendChunkFailure();
      rethrow;
    }

    switch (chunk) {
      case gemma.TextResponse(:final token):
        fullText.write(token);
      case final gemma.FunctionCallResponse call:
        functionCalls.add(call);
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
