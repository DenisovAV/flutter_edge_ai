import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../../services/log.dart';
import '../models/model_catalog.dart';

/// The real [ChatDriver]: one `InferenceChat` over the loaded model, with the
/// advisor's tools declared and the system prompt installed.
class EdgeAiChatDriver implements ChatDriver {
  EdgeAiChatDriver._(this._chat);

  /// A reply plus a short narration; longer answers on a phone cost more
  /// time than they add.
  static const maxOutputTokens = 400;

  /// Tool calls one turn may chain (a search, a payment, a present…); more
  /// than this and the person waits too long for a first word.
  static const maxToolTurns = 4;

  final InferenceChat _chat;

  /// Set by [cancel]; reset when the next send starts. A cancel that lands
  /// between turns is therefore forgotten, which is the wanted behavior:
  /// the person asked for a new turn.
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
      maxOutputTokens: maxOutputTokens,
    );
    logDev(
      'system instruction: ${systemInstruction.length} chars '
      '(~${systemInstruction.length ~/ 4} tokens) of ${spec.maxTokens} context',
    );
    return EdgeAiChatDriver._(chat);
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
            maxToolTurns: maxToolTurns,
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
}
