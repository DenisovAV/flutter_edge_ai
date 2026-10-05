import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../advisor/advisor_surface.dart';
import '../models/model_catalog.dart';
import 'edge_ai_chat_driver.dart';

/// One rendered message in the transcript.
class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.streaming = false});

  final String role; // 'user' | 'advisor'
  final String text;
  final bool streaming;

  ChatMessage copyWith({String? text, bool? streaming}) =>
      ChatMessage(role: role, text: text ?? this.text, streaming: streaming ?? this.streaming);
}

/// A card or prompt the model (or the app) asked to show.
class ShownComponent {
  const ShownComponent({required this.request, this.result, this.answered = false});
  final PresentRequest request;
  final ToolResult? result;

  /// True once the person answered an interaction component; it then renders
  /// collapsed so the conversation keeps its history without live buttons.
  final bool answered;

  ShownComponent copyWith({bool? answered}) =>
      ShownComponent(request: request, result: result, answered: answered ?? this.answered);
}

/// Messages and components interleaved in the order they happened.
sealed class TimelineEntry {
  const TimelineEntry();
}

class MessageEntry extends TimelineEntry {
  const MessageEntry(this.message);
  final ChatMessage message;
}

class ComponentEntry extends TimelineEntry {
  const ComponentEntry(this.shown);
  final ShownComponent shown;
}

/// Everything the chat panel renders.
class ChatState {
  const ChatState({
    this.timeline = const [],
    this.activeTool,
    this.busy = false,
    this.policyFlags = const [],
    this.guardNote,
    this.error,
    this.ready = false,
  });

  final List<TimelineEntry> timeline;
  final String? activeTool;
  final bool busy;
  final List<PolicyFlag> policyFlags;
  final String? guardNote;
  final String? error;
  final bool ready;

  List<ChatMessage> get messages => [
    for (final e in timeline)
      if (e is MessageEntry) e.message,
  ];
  List<ShownComponent> get shown => [
    for (final e in timeline)
      if (e is ComponentEntry) e.shown,
  ];

  ChatState copyWith({
    List<TimelineEntry>? timeline,
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
    timeline: timeline ?? this.timeline,
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

/// Null disables the per-turn timeout (tests); the app uses four minutes.
final turnTimeoutProvider = Provider<Duration?>((ref) => const Duration(minutes: 4));

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

/// The opening prompt (Q43): the app, not the model, offers the shopping-mode
/// choice so the first screen demonstrates structured interaction without a
/// model round trip. Answering sets the mode locally and tells the model.
const Map<String, (ShoppingMode, String)> openingChoices = {
  'mode-browsing': (ShoppingMode.browsing, 'I\'m just looking for now.'),
  'mode-practical': (ShoppingMode.practical, 'I want practical options that fit my budget.'),
  'mode-buying': (ShoppingMode.buying, 'I\'m buying now and want to work through the numbers.'),
  'mode-dreaming': (ShoppingMode.dreaming, 'Let\'s have some fun and look at a dream car.'),
};

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
      state = ChatState(ready: true, timeline: [ComponentEntry(_openingPrompt(profile))]);
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Could not start the advisor: $e');
    }
  }

  ShownComponent _openingPrompt(BuyerProfile profile) {
    final v = PresentRequest.validate({
      'component': 'choice',
      'props': {
        'question': profile.mode == null
            ? 'How are you shopping today?'
            : 'Pick up where you left off, or change how you\'re shopping:',
        'options': [
          {'id': 'mode-browsing', 'label': 'Just looking'},
          {'id': 'mode-practical', 'label': 'Practical options'},
          {'id': 'mode-buying', 'label': 'Buying now'},
          {'id': 'mode-dreaming', 'label': 'Dream car'},
        ],
      },
    }, resultTool: null);
    return ShownComponent(request: v.request!);
  }

  void _replaceEntry(int index, TimelineEntry entry) {
    final t = [...state.timeline];
    t[index] = entry;
    state = state.copyWith(timeline: t);
  }

  /// Marks every unanswered interaction component as answered, so old chips
  /// stop being live once the conversation moves on.
  List<TimelineEntry> _retireInteractions(List<TimelineEntry> timeline) => [
    for (final e in timeline)
      if (e is ComponentEntry && e.shown.request.component.isInteraction && !e.shown.answered)
        ComponentEntry(e.shown.copyWith(answered: true))
      else
        e,
  ];

  Future<void> send(String text) async {
    final pipeline = _pipeline;
    if (pipeline == null || state.busy || text.trim().isEmpty) return;
    final userMsg = ChatMessage(role: 'user', text: text.trim());
    var reply = const ChatMessage(role: 'advisor', text: '', streaming: true);
    state = state.copyWith(
      timeline: [
        ..._retireInteractions(state.timeline),
        MessageEntry(userMsg),
        MessageEntry(reply),
      ],
      busy: true,
      clearGuardNote: true,
      clearError: true,
      policyFlags: const [],
    );
    var replyIndex = state.timeline.length - 1;
    void updateReply(ChatMessage m) {
      reply = m;
      _replaceEntry(replyIndex, MessageEntry(m));
    }

    try {
      final timeout = ref.read(turnTimeoutProvider);
      var events = pipeline.run(text.trim());
      if (timeout != null) {
        events = events.timeout(
          timeout,
          onTimeout: (sink) =>
              sink.addError(TimeoutException('The advisor took too long to answer.')),
        );
      }
      debugPrint('[motormind] turn start');
      await for (final e in events) {
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
            // Components go in front of the streaming reply so the narration
            // reads as commentary on the card above it.
            final t = [...state.timeline];
            t.insert(replyIndex, ComponentEntry(ShownComponent(request: request, result: result)));
            replyIndex += 1;
            state = state.copyWith(timeline: t);
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
      final msg = _friendly(e);
      updateReply(reply.copyWith(text: reply.text.isEmpty ? msg : reply.text, streaming: false));
      state = state.copyWith(error: msg);
    } finally {
      debugPrint('[motormind] turn done');
      state = state.copyWith(busy: false, clearActiveTool: true);
    }
  }

  /// Answer a choice prompt. Opening-mode choices set the mode locally and
  /// send a sentence; other choices send the label the person tapped.
  Future<void> choose(String id, String label) async {
    final opening = openingChoices[id];
    if (opening != null) {
      final (mode, sentence) = opening;
      _pipeline?.profile = (_pipeline?.profile ?? const BuyerProfile()).applyUpdate({
        'shopping_mode': mode.name,
      });
      return send(sentence);
    }
    return send(label);
  }

  BuyerProfile get profile => _pipeline?.profile ?? const BuyerProfile();

  static String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('exceeds available state') || s.contains('context')) {
      return 'The conversation grew past what this model can hold in memory. Start a new conversation to continue.';
    }
    if (e is TimeoutException) return e.message ?? 'The advisor took too long to answer.';
    return 'Something went wrong: $s';
  }
}
