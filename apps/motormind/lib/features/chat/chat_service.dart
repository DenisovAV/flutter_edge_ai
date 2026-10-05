import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../advisor/advisor_surface.dart';
import '../models/model_catalog.dart';
import 'edge_ai_chat_driver.dart';

/// One rendered message in the transcript.
class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.streaming = false});

  final String role; // 'user' | 'advisor' | 'system'
  final String text;
  final bool streaming;

  ChatMessage copyWith({String? text, bool? streaming}) =>
      ChatMessage(role: role, text: text ?? this.text, streaming: streaming ?? this.streaming);
}

/// A card or prompt the model asked to show, kept in order with messages.
class ShownComponent {
  const ShownComponent({required this.request, this.result});
  final PresentRequest request;
  final ToolResult? result;
}

/// Everything the chat panel renders.
class ChatState {
  const ChatState({
    this.messages = const [],
    this.shown = const [],
    this.activeTool,
    this.busy = false,
    this.policyFlags = const [],
    this.guardNote,
    this.error,
    this.ready = false,
  });

  final List<ChatMessage> messages;
  final List<ShownComponent> shown;
  final String? activeTool;
  final bool busy;
  final List<PolicyFlag> policyFlags;
  final String? guardNote;
  final String? error;
  final bool ready;

  ChatState copyWith({
    List<ChatMessage>? messages,
    List<ShownComponent>? shown,
    String? activeTool,
    bool clearActiveTool = false,
    bool? busy,
    List<PolicyFlag>? policyFlags,
    String? guardNote,
    bool clearGuardNote = false,
    String? error,
    bool clearError = false,
    bool? ready,
  }) => ChatState(
    messages: messages ?? this.messages,
    shown: shown ?? this.shown,
    activeTool: clearActiveTool ? null : (activeTool ?? this.activeTool),
    busy: busy ?? this.busy,
    policyFlags: policyFlags ?? this.policyFlags,
    guardNote: clearGuardNote ? null : (guardNote ?? this.guardNote),
    error: clearError ? null : (error ?? this.error),
    ready: ready ?? this.ready,
  );
}

/// Factory seam so tests can inject a scripted [ChatDriver].
typedef ChatDriverFactory = Future<ChatDriver> Function(String systemInstruction);

final chatDriverFactoryProvider = Provider<ChatDriverFactory?>((ref) => null);

final promptAssetsProvider = FutureProvider<SystemPromptBuilder>((ref) async {
  final persona = await rootBundle.loadString('assets/prompts/persona.md');
  final policy = await rootBundle.loadString('assets/prompts/policy.md');
  final modes = await rootBundle.loadString('assets/prompts/modes.md');
  return SystemPromptBuilder(persona: persona, policy: policy, modeGuidance: _parseModes(modes));
});

Map<ShoppingMode, String> _parseModes(String md) {
  final out = <ShoppingMode, String>{};
  ShoppingMode? current;
  final buf = StringBuffer();
  void flush() {
    final mode = current;
    if (mode != null) out[mode] = buf.toString().trim();
    buf.clear();
  }

  for (final line in md.split('\n')) {
    if (line.startsWith('# ')) {
      flush();
      final name = line.substring(2).trim();
      current = ShoppingMode.values.where((m) => m.name == name).firstOrNull;
    } else {
      buf.writeln(line);
    }
  }
  flush();
  return out;
}

final chatServiceProvider = NotifierProvider<ChatService, ChatState>(ChatService.new);

class ChatService extends Notifier<ChatState> {
  TurnPipeline? _pipeline;
  ChatDriver? _driver;

  @override
  ChatState build() {
    ref.onDispose(() => _driver?.close());
    return const ChatState();
  }

  /// Opens a chat on the active model. Call again to start a new conversation.
  Future<void> start() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final builder = await ref.read(promptAssetsProvider.future);
      final profile = _pipeline?.profile ?? const BuyerProfile();
      final instruction = builder.build(profile: profile);
      final factory = ref.read(chatDriverFactoryProvider);
      ChatDriver driver;
      if (factory != null) {
        driver = await factory(instruction);
      } else {
        final models = ref.read(advisorModelServiceProvider.notifier);
        final model = models.loadedModel;
        final activeId = ref.read(advisorModelServiceProvider).value?.activeId;
        final spec = activeId == null ? null : ModelCatalog.byId(activeId);
        if (model == null || spec == null) {
          state = state.copyWith(
            busy: false,
            error: 'No model is loaded. Open Models and choose one.',
          );
          return;
        }
        driver = await EdgeAiChatDriver.open(model, spec, systemInstruction: instruction);
      }
      await _driver?.close();
      _driver = driver;
      _pipeline = TurnPipeline(driver: driver, profile: profile);
      state = const ChatState(ready: true);
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Could not start the advisor: $e');
    }
  }

  Future<void> send(String text) async {
    final pipeline = _pipeline;
    if (pipeline == null || state.busy || text.trim().isEmpty) return;
    final userMsg = ChatMessage(role: 'user', text: text.trim());
    var reply = const ChatMessage(role: 'advisor', text: '', streaming: true);
    state = state.copyWith(
      messages: [...state.messages, userMsg, reply],
      busy: true,
      clearGuardNote: true,
      clearError: true,
      policyFlags: const [],
    );
    void updateReply(ChatMessage m) {
      reply = m;
      final msgs = [...state.messages];
      msgs[msgs.length - 1] = m;
      state = state.copyWith(messages: msgs);
    }

    try {
      await for (final e in pipeline.run(text.trim())) {
        switch (e) {
          case TextDelta(:final text):
            updateReply(reply.copyWith(text: reply.text + text));
          case ThinkingDelta():
            break;
          case ToolStarted(:final name):
            state = state.copyWith(activeTool: name);
          case ToolFinished():
            state = state.copyWith(clearActiveTool: true);
          case ProfileUpdated():
            break;
          case Presented(:final request, :final result):
            state = state.copyWith(
              shown: [
                ...state.shown,
                ShownComponent(request: request, result: result),
              ],
            );
            ref.read(surfaceProvider.notifier).request(request.surface);
          case PresentRejected():
            state = state.copyWith(clearActiveTool: true);
          case GuardTripped(:final report, :final replaced):
            state = state.copyWith(
              guardNote: replaced
                  ? 'The advisor\'s wording was replaced because it contained numbers not from a calculation.'
                  : 'Checking numbers: ${report.unmatched.map((m) => m.raw).join(', ')}',
            );
            if (replaced) updateReply(reply.copyWith(text: ''));
          case PolicyFlagged(:final flags):
            state = state.copyWith(policyFlags: flags);
          case TurnDone(:final narration):
            updateReply(reply.copyWith(text: narration, streaming: false));
        }
      }
    } catch (e) {
      updateReply(
        reply.copyWith(
          text: reply.text.isEmpty ? 'Something went wrong: $e' : reply.text,
          streaming: false,
        ),
      );
      state = state.copyWith(error: e.toString());
    } finally {
      state = state.copyWith(busy: false, clearActiveTool: true);
    }
  }

  /// Answer a choice prompt: sends the chosen label as the user's turn.
  Future<void> choose(String label) => send(label);

  BuyerProfile get profile => _pipeline?.profile ?? const BuyerProfile();
}
