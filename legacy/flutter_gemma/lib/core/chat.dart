import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/extensions.dart';
import 'package:flutter_gemma/core/function_call_parser.dart';
import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model_response.dart';
import 'package:flutter_gemma/core/parsing/sdk_response_parser.dart';
import 'package:flutter_gemma/core/tool.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart';
import 'package:mutex/mutex.dart';

import 'model.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Default maximum length for function call buffer before flushing as text.
/// Must accommodate verbose formats (DeepSeek tags, parallel calls).
const int defaultMaxFunctionBufferLength = 1024;

class InferenceChat {
  final Future<InferenceModelSession> Function()? sessionCreator;
  final int maxTokens;
  final int tokenBuffer;
  final bool supportImage;
  final bool supportAudio;
  final bool supportsFunctionCalls;
  final int maxFunctionBufferLength;
  final ModelType modelType; // Add modelType parameter
  final bool isThinking; // Add isThinking flag for thinking models
  final ModelFileType fileType; // Add fileType parameter
  final ToolChoice toolChoice; // Tool calling mode
  late InferenceModelSession session;
  final List<Tool> _tools;

  /// Tools available to this chat, fixed for the chat's lifetime. A cached
  /// unmodifiable VIEW over `_tools` (allocated once, reflects the backing
  /// list) — `tools.isNotEmpty` is read once per generated token on the
  /// streaming path, so a per-read `List.unmodifiable(_tools)` copy would be
  /// an O(tools) allocation on the hottest generation loop.
  late final List<Tool> tools = UnmodifiableListView(_tools);

  /// Engine-supplied override for [runtimeInjectsToolDeclarations]; `null` means
  /// "derive from the model's function-call format".
  final bool? _runtimeInjectsToolDeclarationsOverride;

  /// Whether the runtime/SDK injects the tool declarations itself, so this chat
  /// must NOT weave its own JSON tools prompt (that would double-wrap them). The
  /// engine's explicit override wins; absent one it derives from the model's
  /// [FunctionCallFormat] (true for SDK-passthrough models: Gemma 4, and
  /// FunctionGemma on `.litertlm`). This replaces the former hardcoded
  /// `modelType == ModelType.gemma4` check, so an engine that injects tools
  /// natively could opt in for any model type. No shipping engine sets the
  /// override yet (both models get `true` via their format).
  ///
  /// NOTE: this governs the INPUT side only (skipping declaration injection).
  /// Reading tool calls BACK is still keyed off
  /// [FunctionCallParser.usesSdkPassthrough] (see [generateChatResponse] /
  /// [generateChatResponseAsync]), which is model-format-derived and not
  /// per-chat overridable — so an engine that sets this `true` on a
  /// non-passthrough model gets calls parsed from the text stream, not from a
  /// structured SDK response.
  late final bool runtimeInjectsToolDeclarations =
      _runtimeInjectsToolDeclarationsOverride ??
      FunctionCallParser.runtimeInjectsToolDeclarations(
        modelType,
        fileType: fileType,
      );

  /// Serializes genai_primitives sendMessage/generateContent calls so
  /// concurrent turns can't interleave staging into the shared session buffer.
  ///
  /// Internal to the `package:flutter_gemma/genai.dart` extension — not part of
  /// the public API. External `acquire()`/`release()` would deadlock the chat.
  @internal
  final Mutex genaiLock = Mutex();

  final List<Message> _fullHistory = [];
  final List<Message> _prefixes =
      []; // Prefix messages (tools prompt + context message) for replay across sessions
  final List<Message> _modelHistory = [];
  int _currentTokens = 0;
  bool _toolsInstructionSent =
      false; // Flag to track if tools instruction was sent

  /// Determines if model history should be cleared after each turn
  /// FunctionGemma requires single-turn mode (no multi-turn context)
  bool get _isSingleTurnModel => modelType == ModelType.functionGemma;

  InferenceChat({
    required this.sessionCreator,
    required this.maxTokens,
    this.tokenBuffer = 2000,
    this.supportImage = false,
    this.supportAudio = false,
    this.supportsFunctionCalls = false,
    this.maxFunctionBufferLength = defaultMaxFunctionBufferLength,
    this._tools = const [],
    this.modelType =
        ModelType.gemmaIt, // Default to gemmaIt for backward compatibility
    this.isThinking = false, // Default to false for backward compatibility
    this.fileType =
        ModelFileType.task, // Default to task for backward compatibility
    this.toolChoice =
        ToolChoice.auto, // Default to auto for backward compatibility
    bool?
    runtimeInjectsToolDeclarations, // engine override; null → derive from format
    String?
    systemInstruction, // kept for API compatibility, forwarded to session via sessionCreator
  }) : _runtimeInjectsToolDeclarationsOverride = runtimeInjectsToolDeclarations;

  List<Message> get fullHistory => List.unmodifiable(_fullHistory);

  int get currentTokens => _currentTokens;

  Future<void> initSession() async {
    session = await sessionCreator!();
  }

  Future<void> addQuery(Message message) async {
    await addQueryChunk(message);
  }

  Future<void> addQueryChunk(
    Message message, [
    bool noTool = false,
    bool prefix = false,
  ]) async {
    var messageToSend = message;

    // Only add tools prompt for the first user text message (not a tool response)
    // and only if the model supports function calls.
    // Runtime-injected declarations are exempt: when the runtime/SDK renders the
    // tools itself (today the `tools_json` LiteRT-LM gets at conversation
    // creation for Gemma 4 and for FunctionGemma on .litertlm; in future, e.g. a
    // web Prompt API arm passing native `tools`), a Dart-side prompt injection
    // would double-wrap them. Gated on [runtimeInjectsToolDeclarations], not a
    // hardcoded model type.
    if (message.isUser &&
        message.type == MessageType.text &&
        !_toolsInstructionSent &&
        tools.isNotEmpty &&
        !noTool &&
        supportsFunctionCalls &&
        toolChoice != ToolChoice.none &&
        !runtimeInjectsToolDeclarations) {
      _toolsInstructionSent = true;
      final toolsPrompt = createToolsPrompt();

      // Create tools prompt message for both storage and session
      final toolsPromptMessage = Message(text: toolsPrompt, isUser: true);

      // Send to session
      await session.addQueryChunk(toolsPromptMessage);

      // Store in _prefixes for replay
      _prefixes.add(toolsPromptMessage);
    } else if (!supportsFunctionCalls && tools.isNotEmpty && !noTool) {
      // Log warning if model doesn't support function calls but tools are provided
      gemmaLog(
        'WARNING: Model does not support function calls, but tools were provided. Tools will be ignored.',
      );
    }

    // Qwen3: append /no_think to suppress thinking at model level when not requested
    if (!isThinking && modelType == ModelType.qwen3 && message.isUser) {
      messageToSend = messageToSend.copyWith(
        text: '${messageToSend.text} /no_think',
      );
    }

    // --- DETAILED LOGGING ---
    if (kDebugMode) {
      final historyForLogging = _modelHistory.map((m) => m.text).join('\n');
      gemmaLog('--- Sending to Native ---');
      gemmaLog('History:\n$historyForLogging', level: GemmaLogLevel.verbose);
      gemmaLog(
        'Current Message:\n${messageToSend.text}',
        level: GemmaLogLevel.verbose,
      );
      gemmaLog('-------------------------');
    }
    // --- END LOGGING ---

    await session.addQueryChunk(messageToSend);

    // Store message in history
    _fullHistory.add(messageToSend);
    // If this is a prefix message, add to _prefixes
    if (prefix) {
      _prefixes.add(message);
    } else {
      _modelHistory.add(message);
    }

    if (message.hasImage) {
      _currentTokens += 257;
    }
  }

  Future<ModelResponse> generateChatResponse() async {
    gemmaLog('InferenceChat: Getting response from native model...');
    final response = await session.getResponse();
    final cleanedResponse = ModelThinkingFilter.cleanResponse(
      response,
      isThinking: isThinking,
      modelType: modelType,
      fileType: fileType,
    );

    // SDK-passthrough path (Gemma 4, and FunctionGemma on .litertlm): the SDK
    // already parsed the model's call tokens into structured `tool_calls` JSON.
    // Read it from session.lastRawResponse before falling back to the legacy
    // regex parser on cleanedResponse. Keyed off the format (mirrors the
    // streaming path below), not a hardcoded model type.
    if (FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType) &&
        tools.isNotEmpty &&
        supportsFunctionCalls &&
        toolChoice != ToolChoice.none &&
        session is RawSdkResponseSession) {
      final raw = (session as RawSdkResponseSession).lastRawResponse;
      if (raw != null) {
        final allCalls = SdkResponseParser.extractToolCalls(raw);
        if (allCalls.isNotEmpty) {
          gemmaLog(
            'InferenceChat: Detected ${allCalls.length} SDK-parsed tool call(s)',
          );
          // Strip Gemma 4 escape tokens (`<|"|>`) before persisting to history.
          // Keeping raw lets the SDK echo those tokens back into the next
          // prompt and the model reproduces them in later tool_calls (#248).
          final cleanRaw = SdkResponseParser.cleanRawForHistory(raw);
          final toolCallMessage = Message.toolCall(text: cleanRaw);
          _fullHistory.add(toolCallMessage);
          _modelHistory.add(toolCallMessage);
          if (allCalls.length == 1) return allCalls.first;
          return ParallelFunctionCallResponse(calls: allCalls);
        }
      }
    }

    if (cleanedResponse.isEmpty) {
      gemmaLog(
        'InferenceChat: Raw response from native model is EMPTY after cleaning.',
      );
      return const TextResponse(''); // Return TextResponse instead of String
    }

    gemmaLog(
      'InferenceChat: Raw response from native model:\n--- START ---\n$cleanedResponse\n--- END ---',
      level: GemmaLogLevel.verbose,
    );

    // Try to parse as function call if tools are available and model supports function calls
    if (tools.isNotEmpty &&
        supportsFunctionCalls &&
        toolChoice != ToolChoice.none) {
      final allCalls = FunctionCallParser.parseAll(
        cleanedResponse,
        modelType: modelType,
      );
      if (allCalls.isNotEmpty) {
        gemmaLog(
          'InferenceChat: Detected ${allCalls.length} function call(s) in sync response',
        );
        final toolCallMessage = Message.toolCall(text: cleanedResponse);
        _fullHistory.add(toolCallMessage);
        _modelHistory.add(toolCallMessage);
        gemmaLog(
          'InferenceChat: Added tool call to history: ${toolCallMessage.text}',
          level: GemmaLogLevel.verbose,
        );
        if (allCalls.length == 1) {
          return allCalls.first;
        }
        return ParallelFunctionCallResponse(calls: allCalls);
      }
    }

    // Regular text response
    final chatMessage = Message(text: cleanedResponse, isUser: false);
    _fullHistory.add(chatMessage);
    _modelHistory.add(chatMessage);

    // Clear model history for single-turn models (e.g., FunctionGemma)
    if (_isSingleTurnModel) {
      gemmaLog(
        'InferenceChat: Single-turn model detected, clearing model history...',
      );
      _modelHistory.clear();
      _prefixes.clear();
      _currentTokens = 0;
      _toolsInstructionSent = false;

      // Recreate session to clear native state
      await session.close();
      session = await sessionCreator!();
      gemmaLog('InferenceChat: Model history cleared and session recreated');
    }

    return TextResponse(
      cleanedResponse,
    ); // Return TextResponse instead of String
  }

  /// Streams this turn's response token-by-token.
  ///
  /// INVARIANT (critical for every consumer): each yielded [FunctionCallResponse]
  /// / [ParallelFunctionCallResponse] has ALREADY been committed to the
  /// persistent chat history (`_fullHistory` + `_modelHistory`) at the moment it
  /// is yielded — committed *before* the yield so a tool-response feeds in AFTER
  /// it in history order. Because the call is committed on yield, any consumer
  /// that collects these calls MUST answer every one (via [addQueryChunk] with a
  /// [Message.toolResponse]) on EVERY exit path — normal completion,
  /// cancellation, a tool throwing, AND a mid-stream stream error — or the
  /// committed call is left dangling with no response and poisons the next turn
  /// on this reused chat. [generateChatResponseWithTools] is the reference
  /// implementation that balances all four paths; new consumers should prefer it
  /// over re-driving this stream directly.
  Stream<ModelResponse> generateChatResponseAsync() async* {
    gemmaLog('InferenceChat: Starting async stream generation');
    final buffer = StringBuffer();

    // Smart function handling mode - continuous scanning for JSON patterns
    String funcBuffer = '';

    gemmaLog('InferenceChat: Starting to iterate over native tokens...');

    // Track if we emitted a function call (to record correct history and skip session clearing)
    bool emittedFunctionCall = false;

    // SDK-passthrough tool-call suppression (Gemma 4, and FunctionGemma on
    // .litertlm; keyed off the format, not the model — see
    // FunctionCallParser.usesSdkPassthrough). The
    // C++ runtime streams a tool-call turn as the raw
    // `{"role":"assistant","tool_calls":[...]}` JSON (one or more concatenated
    // objects) AND exposes it via lastRawResponse. The passthrough format reports
    // "no function call in text", so the funcBuffer below never suppresses those
    // tokens — without this they leak into the text channel (agent
    // TextChunkEvent / voice synthesis). We classify the turn on its first
    // non-whitespace char: a '{' means a tool-call JSON turn, which we swallow
    // (the structured call is surfaced from lastRawResponse at end-of-stream);
    // anything else is plain text and streams normally. Other formats are
    // excluded by the guard below, so this first-char probe only ever runs for
    // the passthrough format — it never misfires on a text-stream format's
    // JSON-ish output. Invariant assumed: a passthrough turn is EITHER all
    // tool-call JSON OR all text, never prose-then-JSON — Gemma 4's SDK emits a
    // pure tool_calls object for a call, so the first-char classification holds.
    final bool sdkPassthrough =
        FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType) &&
        tools.isNotEmpty &&
        supportsFunctionCalls &&
        toolChoice != ToolChoice.none &&
        session is RawSdkResponseSession;
    bool sdkClassified = false; // has this turn been classified yet?
    bool sdkSwallow = false; // swallowing a tool-call JSON stream?
    String sdkProbe = ''; // pre-classification token accumulator
    final sdkSwallowed =
        StringBuffer(); // swallowed JSON (fallback if unparsed)

    final originalStream = session.getResponseAsync().map(
      (token) => TextResponse(token),
    );

    // Apply thinking filter for models that may generate <think> tags.
    // enable_thinking=false is passed via extraContext for .litertlm but is not
    // reliable for all model bundles — keep filter as safety net.
    final bool modelCanThink =
        modelType == ModelType.deepSeek ||
        modelType == ModelType.qwen ||
        modelType == ModelType.qwen3 ||
        modelType == ModelType.gemmaIt;
    final Stream<ModelResponse> filteredStream = (isThinking || modelCanThink)
        ? ModelThinkingFilter.filterThinkingStream(
            originalStream,
            modelType: modelType,
          )
        : originalStream;

    // If user didn't request thinking, discard ThinkingResponse events
    final Stream<ModelResponse> thinkingHandledStream = isThinking
        ? filteredStream
        : filteredStream.where((r) => r is! ThinkingResponse);

    await for (final response in thinkingHandledStream) {
      if (response is TextResponse) {
        final token = response.token;
        if (kDebugMode) {
          gemmaLog(
            'InferenceChat: Received filtered token: "$token"',
            level: GemmaLogLevel.verbose,
          );
        }

        // Gemma 4 SDK-passthrough classification (see `sdkPassthrough` above).
        // Runs before the generic funcBuffer scanning, which is a no-op for the
        // passthrough format anyway (it never detects a call in the text stream).
        if (sdkPassthrough) {
          if (sdkSwallow) {
            // Inside a tool-call JSON stream — swallow every token.
            sdkSwallowed.write(token);
            continue;
          }
          if (!sdkClassified) {
            sdkProbe += token;
            final trimmed = sdkProbe.trimLeft();
            if (trimmed.isEmpty) continue; // whitespace only — keep probing
            sdkClassified = true;
            if (trimmed.startsWith('{')) {
              // Tool-call JSON turn — swallow this and all following tokens.
              sdkSwallow = true;
              sdkSwallowed.write(sdkProbe);
              continue;
            }
            // Plain-text turn — emit the probed prefix, then stream the rest.
            yield TextResponse(sdkProbe);
            buffer.write(sdkProbe);
            continue;
          }
          // Already classified as plain text — stream token-by-token.
          yield response;
          buffer.write(token);
          continue;
        }

        // Track if this token should be added to buffer (default true)
        bool shouldAddToBuffer = true;

        // Continuous scanning for function calls in text - for models like DeepSeek
        if (tools.isNotEmpty &&
            supportsFunctionCalls &&
            toolChoice != ToolChoice.none) {
          // Check if we're currently buffering potential JSON
          if (funcBuffer.isNotEmpty) {
            // We're already buffering - add token and check for completion
            funcBuffer += token;
            if (kDebugMode) {
              gemmaLog(
                'InferenceChat: Buffering token: "$token", total: ${funcBuffer.length} chars',
                level: GemmaLogLevel.verbose,
              );
            }

            // Check if we now have a complete JSON
            if (FunctionCallParser.isFunctionCallComplete(
              funcBuffer,
              modelType: modelType,
            )) {
              // First try to extract message from any JSON with message field
              try {
                final jsonData = jsonDecode(funcBuffer);
                if (jsonData is Map<String, dynamic> &&
                    jsonData.containsKey('message')) {
                  // Found JSON with message field - extract and display the message
                  final message = jsonData['message'] as String;
                  if (kDebugMode) {
                    gemmaLog(
                      'InferenceChat: Extracted message from JSON: "$message"',
                      level: GemmaLogLevel.verbose,
                    );
                  }
                  yield TextResponse(message);
                  funcBuffer = '';
                  shouldAddToBuffer = false; // Don't add JSON tokens to buffer
                  continue;
                }
              } catch (e) {
                gemmaLog(
                  'InferenceChat: Failed to parse JSON for message extraction: $e',
                );
              }

              // If no message field found, try parsing as function call(s)
              final allCalls = FunctionCallParser.parseAll(
                funcBuffer,
                modelType: modelType,
              );
              if (allCalls.isNotEmpty) {
                gemmaLog(
                  'InferenceChat: Found ${allCalls.length} function call(s) in complete buffer!',
                );
                emittedFunctionCall = true;
                // Add function call to history IMMEDIATELY (before yielding)
                // so tool response from caller comes AFTER in history order
                final toolCallMessage = Message.toolCall(text: funcBuffer);
                _fullHistory.add(toolCallMessage);
                _modelHistory.add(toolCallMessage);
                gemmaLog(
                  'InferenceChat: Added function call to history before yielding',
                );
                if (allCalls.length == 1) {
                  yield allCalls.first;
                } else {
                  yield ParallelFunctionCallResponse(calls: allCalls);
                }
                funcBuffer = '';
                shouldAddToBuffer = false;
                continue;
              } else {
                // Not a valid function call - emit as text and clear buffer
                gemmaLog('InferenceChat: Invalid JSON, emitting as text');
                yield TextResponse(funcBuffer);
                funcBuffer = '';
                shouldAddToBuffer = false;
                continue;
              }
            }

            // If buffer gets too long without completing, flush as text
            if (funcBuffer.length > maxFunctionBufferLength) {
              gemmaLog(
                'InferenceChat: Buffer too long without completion, flushing as text',
              );
              yield TextResponse(funcBuffer);
              funcBuffer = '';
              shouldAddToBuffer = false;
              continue;
            }

            // Still buffering, don't emit yet
            shouldAddToBuffer = false;
          } else {
            // Not currently buffering - check if this token starts a function call
            if (FunctionCallParser.isFunctionCallStart(
              token,
              modelType: modelType,
            )) {
              if (kDebugMode) {
                gemmaLog(
                  'InferenceChat: Found potential function call start in token: "$token"',
                  level: GemmaLogLevel.verbose,
                );
              }
              funcBuffer = token;
              shouldAddToBuffer =
                  false; // Don't add to main buffer while we determine if it's JSON
            } else if (modelType == ModelType.functionGemma &&
                token.trim() == functionGemmaEndCall) {
              // The call's closing brace already completed the buffer, so this
              // trailing tag belongs to no call. It is markup, not text —
              // emitting it would show `<end_function_call>` to the user and
              // write it into chat history.
              shouldAddToBuffer = false;
            } else {
              // Normal text token - emit immediately
              if (kDebugMode) {
                gemmaLog(
                  'InferenceChat: Emitting text token: "$token"',
                  level: GemmaLogLevel.verbose,
                );
              }
              yield response;
              shouldAddToBuffer = true; // Add to main buffer for history
            }
          }
        } else {
          // No function processing happening - emit token directly
          if (kDebugMode) {
            gemmaLog(
              'InferenceChat: No function processing, emitting token as text: "$token"',
              level: GemmaLogLevel.verbose,
            );
          }
          yield response;
          shouldAddToBuffer = true; // Add to main buffer for history
        }

        // Add token to buffer only if it should be included in final message
        if (shouldAddToBuffer) {
          buffer.write(token);
        }
      } else {
        // For non-TextResponse (like ThinkingResponse), pass through
        yield response;
      }
    }

    gemmaLog('InferenceChat: Native token stream ended');

    // The stream ended before we classified this Gemma 4 turn (e.g. a
    // whitespace-only reply) — the probed tokens are plain text, flush them.
    if (sdkPassthrough && !sdkClassified && sdkProbe.isNotEmpty) {
      yield TextResponse(sdkProbe);
      buffer.write(sdkProbe);
    }

    final response = buffer.toString();
    gemmaLog(
      'InferenceChat: Complete response accumulated: "$response"',
      level: GemmaLogLevel.verbose,
    );

    // SDK-passthrough path (same guard that swallowed the tool-call JSON above):
    // the structured tool calls live in `lastRawResponse`. Surface them here as
    // the final ModelResponse(s).
    if (sdkPassthrough) {
      final raw = (session as RawSdkResponseSession).lastRawResponse;
      if (raw != null) {
        final allCalls = SdkResponseParser.extractToolCalls(raw);
        if (allCalls.isNotEmpty) {
          gemmaLog(
            'InferenceChat: ${allCalls.length} SDK-parsed tool call(s) at end of stream',
          );
          emittedFunctionCall = true;
          // Record the tool-call in history BEFORE yielding (mirrors the sync
          // SDK path at ~L193 and the JSON paths) — otherwise the caller's
          // tool-response has no matching call and is left orphaned, which
          // corrupts the replayed history when the Gemma 4 session rotates.
          // Strip the Gemma 4 escape tokens first, same as the sync path (#248).
          final cleanRaw = SdkResponseParser.cleanRawForHistory(raw);
          final toolCallMessage = Message.toolCall(text: cleanRaw);
          _fullHistory.add(toolCallMessage);
          _modelHistory.add(toolCallMessage);
          if (allCalls.length == 1) {
            yield allCalls.first;
          } else {
            yield ParallelFunctionCallResponse(calls: allCalls);
          }
        }
      }
    }

    // Safety net: we suppressed a `{`-leading SDK-passthrough stream as a tool
    // call, but lastRawResponse yielded no parseable call. Don't silently drop
    // the model's output — surface the swallowed text (as it leaked pre-fix). It
    // is deliberately NOT re-recorded to history: this only fires on a degenerate
    // turn (a `{`-leading passthrough turn with no extractable tool_calls), where
    // re-appending the JSON-shaped blob as an assistant turn would pollute the
    // model's next-turn context more than omitting it.
    if (sdkSwallow && !emittedFunctionCall && sdkSwallowed.isNotEmpty) {
      gemmaLog(
        'InferenceChat: SDK tool-call stream suppressed but no call parsed — '
        'surfacing raw text (fallback)',
      );
      yield TextResponse(sdkSwallowed.toString());
    }

    // Handle end of stream - process any remaining buffer
    if (funcBuffer.isNotEmpty) {
      gemmaLog(
        'InferenceChat: Processing remaining buffer at end of stream: ${funcBuffer.length} chars',
      );

      // For FunctionGemma, the function call spans response + funcBuffer
      // (e.g., response="<start_function_call>call:fn", funcBuffer="{params}")
      // For JSON models, funcBuffer contains the complete JSON
      final contentToCheck = modelType == ModelType.functionGemma
          ? response + funcBuffer
          : funcBuffer;

      // First try to extract message from JSON if it has message field
      if (FunctionCallParser.isFunctionCallComplete(
        contentToCheck,
        modelType: modelType,
      )) {
        try {
          // For JSON parsing, use funcBuffer (the actual JSON part)
          // For FunctionGemma parsing, use contentToCheck (full function call)
          if (modelType != ModelType.functionGemma) {
            final jsonData = jsonDecode(funcBuffer);
            if (jsonData is Map<String, dynamic> &&
                jsonData.containsKey('message')) {
              final message = jsonData['message'] as String;
              gemmaLog(
                'InferenceChat: Extracted message from end-of-stream JSON: "$message"',
                level: GemmaLogLevel.verbose,
              );
              yield TextResponse(message);
              return;
            }
          }

          // Try to parse as function call(s)
          final allCalls = FunctionCallParser.parseAll(
            contentToCheck,
            modelType: modelType,
          );
          if (allCalls.isNotEmpty) {
            gemmaLog(
              'InferenceChat: ${allCalls.length} function call(s) found at end of stream',
            );
            emittedFunctionCall = true;
            // Add function call to history IMMEDIATELY (before yielding)
            final toolCallMessage = Message.toolCall(text: contentToCheck);
            _fullHistory.add(toolCallMessage);
            _modelHistory.add(toolCallMessage);
            gemmaLog(
              'InferenceChat: Added function call to history at end of stream',
            );
            if (allCalls.length == 1) {
              yield allCalls.first;
            } else {
              yield ParallelFunctionCallResponse(calls: allCalls);
            }
          } else {
            yield TextResponse(funcBuffer);
          }
        } catch (e) {
          gemmaLog('InferenceChat: Failed to parse end-of-stream JSON: $e');
          yield TextResponse(funcBuffer);
        }
      } else {
        gemmaLog(
          'InferenceChat: No complete JSON at end of stream, emitting remaining as text',
        );
        yield TextResponse(funcBuffer);
      }
    }

    try {
      gemmaLog('InferenceChat: Calculating response tokens...');
      final responseTokens = await session.sizeInTokens(response);
      gemmaLog('InferenceChat: Response tokens: $responseTokens');
      _currentTokens += responseTokens;
      gemmaLog('InferenceChat: Current total tokens: $_currentTokens');

      if (_currentTokens >= (maxTokens - tokenBuffer)) {
        gemmaLog('InferenceChat: Token limit reached, recreating session...');
        await _recreateSessionWithReducedChunks();
        gemmaLog('InferenceChat: Session recreated successfully');
      }
    } catch (e) {
      gemmaLog('InferenceChat: Error during token calculation: $e');
    }

    try {
      gemmaLog('InferenceChat: Adding message to history...');
      // For function calls: already added to history when yielded (above)
      // For text responses: add now since they weren't added during streaming.
      // Skip an EMPTY response: a cancelled stream (stopGeneration before any
      // text token) ends with response == '', and writing that empty assistant
      // turn pollutes _modelHistory so later short replies come back empty
      // (#325). "No text produced" is not a turn worth recording.
      if (!emittedFunctionCall && response.isNotEmpty) {
        final chatMessage = Message(text: response, isUser: false);
        gemmaLog(
          'InferenceChat: Created text message object: ${chatMessage.text}',
          level: GemmaLogLevel.verbose,
        );
        _fullHistory.add(chatMessage);
        gemmaLog('InferenceChat: Added to full history');
        _modelHistory.add(chatMessage);
        gemmaLog('InferenceChat: Added to model history');
      } else {
        gemmaLog(
          'InferenceChat: Function call was already added to history when yielded',
        );
      }
      gemmaLog('InferenceChat: Message added to history successfully');

      // Clear model history for single-turn models (e.g., FunctionGemma)
      // BUT only if this was NOT a function call - we need context for tool response
      if (_isSingleTurnModel && !emittedFunctionCall) {
        gemmaLog(
          'InferenceChat: Single-turn model detected (text response), clearing model history...',
        );
        _modelHistory.clear();
        _prefixes.clear();
        _currentTokens = 0;
        _toolsInstructionSent = false;

        // Recreate session to clear native state
        await session.close();
        session = await sessionCreator!();
        gemmaLog('InferenceChat: Model history cleared and session recreated');
      } else if (_isSingleTurnModel && emittedFunctionCall) {
        gemmaLog(
          'InferenceChat: Single-turn model with function call - keeping history for tool response',
        );
      }
    } catch (e) {
      gemmaLog('InferenceChat: Error adding message to history: $e');
      rethrow;
    }

    gemmaLog('InferenceChat: generateChatResponseAsync completed successfully');
  }

  /// Drive flutter_gemma's function-calling loop to completion. Stream this
  /// turn's text/thinking tokens; whenever the model calls a tool, run
  /// [onToolCall] and feed its result back as a tool-response message, then
  /// continue — until a turn has no calls (the model's final answer) or
  /// [maxToolTurns] / [isCancelled] stops it.
  ///
  /// PRECONDITION: the user message must already be staged (call [addQueryChunk]
  /// first), same as [generateChatResponseAsync]. [onToolCall] returns the
  /// `{...}` response map fed back via [Message.toolResponse]. Tool *execution*
  /// is the caller's (tools are app actions); core only parses the call and
  /// drives the loop. [onMaxToolTurns], when supplied, is invoked once if the
  /// loop exhausts [maxToolTurns] without a call-free answer — so a consumer
  /// driving this loop can surface its own terminal signal (e.g. AgentLoop's
  /// MaxIterationsEvent).
  Stream<ModelResponse> generateChatResponseWithTools({
    required FutureOr<Map<String, dynamic>> Function(FunctionCallResponse call)
    onToolCall,
    int maxToolTurns = 8,
    bool Function()? isCancelled,
    void Function()? onMaxToolTurns,
  }) async* {
    if (maxToolTurns < 1) {
      // A cap below 1 would exit before any generation — the already-staged
      // user turn would get NO response and the stream would close empty (a
      // silent no-op). Fail loud (asserts are stripped in release).
      throw RangeError.range(maxToolTurns, 1, null, 'maxToolTurns');
    }
    for (var turn = 0; turn < maxToolTurns; turn++) {
      if (isCancelled?.call() ?? false) return;
      final pending = <FunctionCallResponse>[];
      try {
        await for (final r in generateChatResponseAsync()) {
          // Exhaustive over the sealed ModelResponse: a future subtype fails to
          // compile here instead of silently passing through as text.
          switch (r) {
            case FunctionCallResponse():
              pending.add(r);
            case ParallelFunctionCallResponse(:final calls):
              pending.addAll(calls);
            case TextResponse() || ThinkingResponse():
              yield r; // pass through to the caller's text/thinking stream
          }
        }
      } catch (_) {
        // generateChatResponseAsync commits each tool-call to the persistent
        // history the moment it yields it (see the callsites above). A mid-stream
        // decode error rethrows past the balancing below, leaving a committed
        // call with no tool-response — it dangles and poisons the next turn on
        // this reused chat. Answer the collected calls first, then rethrow the
        // ORIGINAL error (the failure still surfaces to the caller — never
        // hidden).
        if (pending.isNotEmpty) {
          gemmaLog(
            'InferenceChat.generateChatResponseWithTools: generation stream '
            'errored mid-turn; balancing ${pending.length} committed '
            'tool-call(s) before rethrowing.',
          );
        }
        try {
          await _answerToolCalls(pending, const {
            'status': 'failed',
            'error': 'generation stream errored before this tool call ran',
          });
        } catch (balanceError) {
          // The already-errored session rejected the balancing feed too. Do NOT
          // let that mask the original failure — log loudly and still rethrow the
          // original below. The caller's safe recovery is to recreate the session
          // / clearHistory(replayHistory:), which the Dart-side history makes
          // correct once the session is usable again.
          gemmaLog(
            'InferenceChat.generateChatResponseWithTools: could not balance '
            'committed tool-call(s) after a stream error ($balanceError); the '
            'persistent chat history may be left unbalanced — recover by '
            'recreating the session.',
          );
        }
        rethrow;
      }
      if (pending.isEmpty) return; // model's final (call-free) answer

      // generateChatResponseAsync already committed the assistant tool-call(s)
      // to history; EVERY committed call must get a matching tool-response or
      // the (persistent, reused-across-turns) chat is left with a dangling
      // call that poisons the next turn (the model re-issues it or replies
      // empty). So both abnormal exits below balance the history first.
      if (isCancelled?.call() ?? false) {
        // Barge-in after generation, before execution: don't run the tools,
        // but still answer the committed call(s) with a cancelled marker.
        await _answerToolCalls(pending, const {'status': 'cancelled'});
        return;
      }
      for (var i = 0; i < pending.length; i++) {
        if (isCancelled?.call() ?? false) {
          // Barge-in landed mid-turn (between individual tool calls). Don't run
          // the remaining tools' side effects — mirrors AgentLoop's between-call
          // check (agent_loop.dart) — but answer every not-yet-run call (i..end)
          // with a cancelled marker so no committed call is left dangling, then
          // stop. On the voice detach path the per-turn token stays cancelled
          // forever, so a still-running DETACHED loop bails here at the next
          // tool boundary instead of executing the rest of this turn's tools.
          await _answerToolCalls(pending.sublist(i), const {
            'status': 'cancelled',
          });
          return;
        }
        final call = pending[i];
        final Map<String, dynamic> response;
        try {
          response = await onToolCall(call);
        } catch (e) {
          // The app's tool threw. Answer the failed call (and any siblings in
          // this turn not yet run) so the committed call isn't left dangling,
          // then rethrow so the caller sees the failure.
          await addQueryChunk(
            Message.toolResponse(
              toolName: call.name,
              response: {'error': '$e'},
            ),
          );
          await _answerToolCalls(pending.sublist(i + 1), const {
            'status': 'not run — an earlier tool call in this turn failed',
          });
          rethrow;
        }
        await addQueryChunk(
          Message.toolResponse(toolName: call.name, response: response),
        );
      }
    }
    // Exhausted maxToolTurns with calls still pending: each turn's calls WERE
    // answered, but no final call-free generation ran, so the reply may be
    // empty/truncated. Log it (and notify [onMaxToolTurns], so a consumer that
    // drives this loop can surface its own terminal — e.g. AgentLoop's
    // MaxIterationsEvent) — silent truncation would violate the
    // no-masking-failure rule.
    onMaxToolTurns?.call();
    gemmaLog(
      'InferenceChat.generateChatResponseWithTools: hit maxToolTurns '
      '($maxToolTurns) with tool calls still pending; stopping. The reply may '
      'be empty or truncated — the model never produced a call-free answer.',
    );
  }

  /// Feeds a fixed [response] as the tool-response for each of [calls]. Used to
  /// balance history when a turn is cancelled or a tool throws mid-turn, so a
  /// committed tool-call is never left without a matching response.
  Future<void> _answerToolCalls(
    List<FunctionCallResponse> calls,
    Map<String, dynamic> response,
  ) async {
    for (final call in calls) {
      await addQueryChunk(
        Message.toolResponse(toolName: call.name, response: response),
      );
    }
  }

  Future<void> _recreateSessionWithReducedChunks() async {
    while (_currentTokens >= (maxTokens - tokenBuffer) &&
        _modelHistory.isNotEmpty) {
      final removedMessage = _modelHistory.removeAt(0);
      final size = await session.sizeInTokens(removedMessage.text);
      _currentTokens -= size;

      // Count all images (message.images can have multiple)
      final imageCount = removedMessage.images.length;
      if (imageCount > 0) {
        _currentTokens -= imageCount * 257;
      }
    }

    await session.close();
    session = await sessionCreator!();

    // Replay prefixes first (explicit prefix messages)
    for (final prefix in _prefixes) {
      await session.addQueryChunk(prefix);
    }

    // Then replay model history
    for (final message in _modelHistory) {
      await session.addQueryChunk(message);
    }
  }

  Future<void> clearHistory({List<Message>? replayHistory}) async {
    _fullHistory.clear();
    _prefixes.clear();
    _modelHistory.clear();
    _currentTokens = 0;
    _toolsInstructionSent = false;
    await session.close();
    session = await sessionCreator!();

    if (replayHistory != null) {
      for (final message in replayHistory) {
        await addQueryChunk(message);
      }
    }
  }

  bool get supportsImages => supportImage;

  int get imageMessageCount => _fullHistory.where((msg) => msg.hasImage).length;

  Future<void> stopGeneration() => session.stopGeneration();

  Future<void> close() => session.close();

  /// Creates tools prompt based on model type and tool choice.
  /// Made package-private for testing.
  @visibleForTesting
  String createToolsPrompt() {
    if (tools.isEmpty) {
      return '';
    }

    // ToolChoice.none — don't inject tools prompt at all
    if (toolChoice == ToolChoice.none) {
      return '';
    }

    // Explicit routing by ModelType using Dart 3 switch expression
    return switch (modelType) {
      ModelType.functionGemma => _createFunctionGemmaToolsPrompt(),
      // All other models use JSON format
      _ => _createJsonToolsPrompt(),
    };
  }

  String _createJsonToolsPrompt() {
    final toolsPrompt = StringBuffer();

    // Instruction varies by ToolChoice mode
    switch (toolChoice) {
      case ToolChoice.auto:
        toolsPrompt.writeln(
          'You have access to functions. ONLY call a function when the user explicitly requests an action or command (like "change color", "show alert", "set title"). For regular conversation, greetings, and questions, respond normally without calling any functions.',
        );
      case ToolChoice.required:
        toolsPrompt.writeln(
          'You have access to functions. You MUST respond with a function call. Do not respond with plain text. Always select the most appropriate function based on the user\'s message.',
        );
      case ToolChoice.none:
        return ''; // Should not reach here, but defensive
    }

    toolsPrompt.writeln(
      'When you do need to call a function, respond with ONLY the JSON in this format: {"name": function_name, "parameters": {argument: value}}',
    );
    toolsPrompt.writeln(
      'After the function is executed, you will get a response. Then provide a helpful message to the user about what was accomplished.',
    );
    toolsPrompt.writeln('<tool_code>');
    for (final tool in tools) {
      toolsPrompt.writeln(
        '${tool.name}: ${tool.description} Parameters: ${jsonEncode(tool.parameters)}',
      );
    }
    toolsPrompt.writeln('</tool_code>');
    return toolsPrompt.toString();
  }

  String _createFunctionGemmaToolsPrompt() {
    if (toolChoice == ToolChoice.required) {
      // The model's chat_template renders a developer turn of declarations plus
      // an optional system text. Nothing in the format expresses "you must call
      // a function", so honouring `required` would mean inventing tokens the
      // model was never trained on. Say so rather than ignore it.
      gemmaLog(
        'WARNING: ToolChoice.required is not supported by FunctionGemma — its '
        'prompt format cannot express it. Behaving as ToolChoice.auto.',
      );
    }

    final toolsPrompt = StringBuffer();

    // FunctionGemma requires developer turn for tools definition
    toolsPrompt.write('$startTurn$developerPrefix\n');
    toolsPrompt.writeln(
      'You are a model that can do function calling with the following functions',
    );

    for (final tool in tools) {
      toolsPrompt.write(functionGemmaStartDecl);
      toolsPrompt.write('declaration:${tool.name}{');
      toolsPrompt.write(
        'description:$functionGemmaEscape${tool.description}$functionGemmaEscape',
      );

      // The template gates `parameters` on the parameters map itself, and emits
      // `type` independently of `properties`. So a no-argument tool still gets
      // `parameters:{type:<escape>OBJECT<escape>}` — gating on `properties`
      // dropped the whole block for `get_time`-style tools.
      if (tool.parameters.isNotEmpty) {
        final properties =
            tool.parameters['properties'] as Map<String, dynamic>?;
        final required = tool.parameters['required'] as List<dynamic>?;

        final parts = <String>[];
        if (properties != null && properties.isNotEmpty) {
          parts.add(
            'properties:{${_formatFunctionGemmaProperties(properties, tool.name)}}',
          );
        }
        if (required != null && required.isNotEmpty) {
          parts.add('required:[${_formatFunctionGemmaRequired(required)}]');
        }
        parts.add('type:${functionGemmaEscape}OBJECT$functionGemmaEscape');

        toolsPrompt.write(',parameters:{${parts.join(',')}}');
      }

      toolsPrompt.writeln('}$functionGemmaEndDecl');
    }

    toolsPrompt.write('$endTurn\n');
    return toolsPrompt.toString();
  }

  // The helpers below mirror FunctionGemma's own `chat_template.jinja`
  // (`format_function_declaration` / `format_argument`). The template is the
  // spec — the model was trained on what it renders, so any divergence here
  // feeds the model a declaration shape it has never seen.

  /// Property names the template reserves for structure. It skips any property
  /// that collides with one, so we skip it too rather than emit a declaration
  /// the model cannot parse.
  static const _functionGemmaStructuralKeys = {
    'description',
    'type',
    'properties',
    'required',
    'nullable',
  };

  String _formatFunctionGemmaRequired(List<dynamic> required) => required
      .map(
        (r) =>
            '$functionGemmaEscape${functionGemmaScalar(r)}$functionGemmaEscape',
      )
      .join(',');

  /// The declaration must name one concrete type per property. `properties` and
  /// `items` imply their type in JSON Schema — reading them is inference, not a
  /// guess. Anything else is unknowable, and guessing STRING would make the
  /// model quote numbers back at us, so say so instead.
  String _inferFunctionGemmaType(
    Map<String, dynamic> schema,
    String toolName,
    String propertyName,
  ) {
    if (schema.containsKey('properties')) return 'OBJECT';
    if (schema.containsKey('items')) return 'ARRAY';
    throw ArgumentError(
      'FunctionGemma requires an explicit type for property "$propertyName" '
      'of tool "$toolName". '
      'Declare one of: string, number, integer, boolean, array, object.',
    );
  }

  String _formatFunctionGemmaProperties(
    Map<String, dynamic> properties,
    String toolName,
  ) {
    final entries = <String>[];

    // NOT `functionGemmaDictsort`: the template sorts, but a tool's properties
    // reach the model in the order the app declared them, and every model
    // fine-tuned before 1.2.3 — including via our own colab — learned that
    // order. On the base model, sorting changed nothing measurable (device A/B
    // on 12 prompts: same hits, same misses). Fidelity to the template is not
    // worth breaking existing fine-tunes. `items` keys and map arguments still
    // dictsort: they are new in 1.2.3 and no prompt ever depended on them.
    for (final name in properties.keys) {
      if (_functionGemmaStructuralKeys.contains(name)) continue;
      final schema = properties[name];
      if (schema is! Map<String, dynamic>) continue;

      final rawType = schema['type'];
      if (rawType is List) {
        // The template renders a union as a Python list repr the model has
        // never seen.
        throw ArgumentError(
          'FunctionGemma does not support union types (property "$name" of '
          'tool "$toolName" declares type: $rawType). '
          'Declare a single type and mark it nullable: true.',
        );
      }
      if (rawType != null && rawType is! String) {
        throw ArgumentError(
          'FunctionGemma property "$name" of tool "$toolName" declares a '
          'non-string type: $rawType.',
        );
      }

      final type =
          (rawType as String?)?.toUpperCase() ??
          _inferFunctionGemmaType(schema, toolName, name);

      final description = schema['description'];
      final property = StringBuffer(
        '$name:{description:$functionGemmaEscape'
        // An explicit null renders empty here, not as Python's `None`.
        '${description == null ? '' : functionGemmaScalar(description)}'
        '$functionGemmaEscape',
      );

      // Validate before the type check: an enum on a NUMBER property is dropped
      // by the template, but a poisoned value is still a caller bug worth naming.
      final enumValues = schema['enum'] as List<dynamic>?;
      if (enumValues != null && enumValues.isNotEmpty) {
        _assertNoSpecialTokens(enumValues);
      }

      switch (type) {
        case 'STRING':
          if (enumValues != null && enumValues.isNotEmpty) {
            property.write(',enum:${functionGemmaArgument(enumValues)}');
          }
        case 'OBJECT':
          final nested = schema['properties'];
          property.write(',properties:{');
          if (nested is Map<String, dynamic>) {
            property.write(_formatFunctionGemmaProperties(nested, toolName));
          }
          property.write('}');
          final nestedRequired = schema['required'] as List<dynamic>?;
          if (nestedRequired != null && nestedRequired.isNotEmpty) {
            property.write(
              ',required:[${_formatFunctionGemmaRequired(nestedRequired)}]',
            );
          }
        case 'ARRAY':
          final items = schema['items'];
          if (items is Map<String, dynamic> && items.isNotEmpty) {
            property.write(
              ',items:{${_formatFunctionGemmaItems(items, toolName)}}',
            );
          }
      }

      property.write(',type:$functionGemmaEscape$type$functionGemmaEscape}');
      entries.add(property.toString());
    }

    return entries.join(',');
  }

  String _formatFunctionGemmaItems(
    Map<String, dynamic> items,
    String toolName,
  ) {
    final parts = <String>[];

    for (final key in functionGemmaDictsort(items.keys)) {
      final value = items[key];
      if (value == null) continue;

      switch (key) {
        case 'properties':
          final nested = value is Map<String, dynamic>
              ? _formatFunctionGemmaProperties(value, toolName)
              : '';
          parts.add('properties:{$nested}');
        case 'required':
          // No emptiness guard here, unlike the object level: the template
          // guards `required` on a property but not inside `items`, so an
          // empty list still renders as `required:[]`.
          if (value is List<dynamic>) {
            parts.add('required:[${_formatFunctionGemmaRequired(value)}]');
          }
        case 'type':
          // An array's element type may itself be a union, e.g. ['string','number'].
          final upper = value is List
              ? value.map((v) => '$v'.toUpperCase()).toList()
              : '$value'.toUpperCase();
          parts.add('type:${functionGemmaArgument(upper)}');
        default:
          parts.add('$key:${functionGemmaArgument(value)}');
      }
    }

    return parts.join(',');
  }

  void _assertNoSpecialTokens(List<dynamic> enumValues) {
    for (final value in enumValues) {
      final str = value.toString();
      if (str.contains(functionGemmaEscape) ||
          str.contains('<start_') ||
          str.contains('<end_')) {
        throw ArgumentError(
          'Enum value "$str" contains FunctionGemma special tokens',
        );
      }
    }
  }
}

/// Filters stop tokens from a model response stream: detects `<end_of_turn>`
/// and terminates the stream there, buffering partial tag matches.
///
/// It existed for .litertlm on iOS, which until 0.14.0 ran through MediaPipe
/// and did not stop at the token. Since 0.14.0 every platform, iOS included,
/// runs .litertlm through LiteRT-LM, which ends the turn natively, so
/// [InferenceChat] no longer applies it. Kept, with its behaviour unchanged,
/// because it is exported.
@Deprecated(
  'No engine needs this since 0.14.0: LiteRT-LM ends the turn natively on '
  'every platform, and InferenceChat no longer applies it. Scheduled for '
  'removal in 2.0.',
)
class StopTokenFilter {
  static const String _stopToken = '<end_of_turn>';

  static Stream<ModelResponse> filterStopTokens(
    Stream<ModelResponse> originalStream, {
    required ModelFileType fileType,
  }) async* {
    // Only apply for litertlm on iOS
    if (fileType != ModelFileType.litertlm ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS) {
      yield* originalStream;
      return;
    }

    String buffer = '';

    await for (final response in originalStream) {
      if (response is TextResponse) {
        buffer += response.token;

        // Check if buffer contains the stop token
        final stopIndex = buffer.indexOf(_stopToken);
        if (stopIndex >= 0) {
          // Emit text before stop token, then stop
          final textBefore = buffer.substring(0, stopIndex);
          if (textBefore.isNotEmpty) {
            yield TextResponse(textBefore);
          }
          return;
        }

        // Check if buffer ends with a partial match of the stop token
        int partialLen = 0;
        for (int i = 1; i <= _stopToken.length && i <= buffer.length; i++) {
          if (buffer.endsWith(_stopToken.substring(0, i))) {
            partialLen = i;
          }
        }

        if (partialLen > 0) {
          // Emit safe portion, keep potential partial match
          final safe = buffer.substring(0, buffer.length - partialLen);
          if (safe.isNotEmpty) {
            yield TextResponse(safe);
          }
          buffer = buffer.substring(buffer.length - partialLen);
        } else {
          // No partial match, emit everything
          if (buffer.isNotEmpty) {
            yield TextResponse(buffer);
          }
          buffer = '';
        }
      } else {
        yield response;
      }
    }

    // Emit any remaining buffer (wasn't a complete stop token)
    if (buffer.isNotEmpty) {
      yield TextResponse(buffer);
    }
  }
}
