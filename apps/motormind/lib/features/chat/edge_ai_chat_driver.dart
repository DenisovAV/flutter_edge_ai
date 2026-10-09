import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../models/model_catalog.dart';

/// The real [ChatDriver]: one `InferenceChat` over the loaded model, with the
/// advisor's tools declared and the system prompt installed.
class EdgeAiChatDriver implements ChatDriver {
  EdgeAiChatDriver._(this._chat, this._model, this._spec);

  final InferenceChat _chat;
  final InferenceModel _model;
  final AdvisorModelSpec _spec;
  bool _cancelled = false;

  static Future<EdgeAiChatDriver> open(
    InferenceModel model,
    AdvisorModelSpec spec, {
    required String systemInstruction,
  }) async {
    final chat = await model.createChat(
      temperature: spec.temperature,
      topK: spec.topK,
      topP: spec.topP,
      tools: [
        for (final t in AdvisorTools.all)
          Tool(name: t.name, description: t.description, parameters: t.parameters),
      ],
      supportsFunctionCalls: spec.supportsTools,
      modelType: spec.modelType,
      systemInstruction: systemInstruction,
      maxOutputTokens: 400,
    );
    if (kDebugMode) {
      debugPrint(
        '[motormind] system instruction: ${systemInstruction.length} chars (~${systemInstruction.length ~/ 4} tokens) of ${spec.maxTokens} context',
      );
    }
    return EdgeAiChatDriver._(chat, model, spec);
  }

  /// Generation errors inside the SDK can surface on an unawaited future
  /// (observed: a context-window overflow during a tool-result prefill). A
  /// zone catches those and fails this stream, so the UI never hangs.
  @override
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall}) {
    final out = StreamController<DriverChunk>();
    runZonedGuarded(
      () async {
        try {
          _cancelled = false;
          await _chat.addQueryChunk(Message.text(text: userText, isUser: true));
          final stream = _chat.generateChatResponseWithTools(
            onToolCall: (call) => onToolCall(call.name, call.args.cast<String, Object?>()),
            maxToolTurns: 4,
            isCancelled: () => _cancelled,
          );
          await for (final r in stream) {
            switch (r) {
              case TextResponse(:final token):
                out.add(DriverText(token));
              case ThinkingResponse(:final content):
                out.add(DriverThinking(content));
              case FunctionCallResponse() || ParallelFunctionCallResponse():
                break; // consumed by the loop
            }
          }
        } catch (e, st) {
          if (!out.isClosed) out.addError(e, st);
        } finally {
          if (!out.isClosed) await out.close();
        }
      },
      (e, st) {
        if (!out.isClosed) {
          out.addError(e, st);
          out.close();
        }
      },
    );
    return out.stream;
  }

  @override
  Future<void> updateSystemInstruction(String instruction) async {
    // The SDK fixes the instruction at chat creation; a new chat would drop
    // history. Left as a no-op until a history-preserving path exists.
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    try {
      await _chat.stopGeneration();
    } catch (_) {
      // Best effort: nothing may be in flight.
    }
  }

  @override
  Future<void> close() => _chat.close();

  String get modelId => _spec.id;
  InferenceModel get model => _model;
}
