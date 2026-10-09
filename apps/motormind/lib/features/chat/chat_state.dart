import 'package:advisor_core/advisor_core.dart';

/// Who wrote a transcript message.
enum MessageRole {
  /// The person, typed or chosen from a prompt.
  user,

  /// Motormind's reply (streamed, then final).
  motormind,

  /// A note the app wrote into the transcript, such as an applied search.
  system,
}

/// One rendered message in the transcript.
class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.streaming = false})
    : isSearchNote = false;

  /// A system note about an applied search; these replace one another.
  const ChatMessage.searchNote(this.text)
    : role = MessageRole.system,
      streaming = false,
      isSearchNote = true;

  final MessageRole role;
  final String text;

  /// True while tokens are still arriving for this message.
  final bool streaming;

  /// True for the one-line search notes (see [ChatMessage.searchNote]).
  final bool isSearchNote;

  ChatMessage copyWith({String? text, bool? streaming}) => isSearchNote
      ? ChatMessage.searchNote(text ?? this.text)
      : ChatMessage(role: role, text: text ?? this.text, streaming: streaming ?? this.streaming);
}

/// A card or prompt the model (or the app) asked to show, with the result it
/// renders from, if any.
class ShownComponent {
  ShownComponent({required this.request, this.result, this.answered = false, int? id})
    : id = id ?? _nextId++;

  static int _nextId = 1;

  /// Identity that survives [copyWith], so "mark answered" finds the card
  /// without relying on object identity.
  final int id;

  final PresentRequest request;
  final ToolResult? result;

  /// True once the person answered an interaction component; it then renders
  /// collapsed so the conversation keeps its history without live buttons.
  final bool answered;

  ShownComponent copyWith({bool? answered}) =>
      ShownComponent(request: request, result: result, answered: answered ?? this.answered, id: id);
}

/// Messages and components interleaved in the order they happened.
sealed class TimelineEntry {
  const TimelineEntry();
}

/// A message in the timeline.
class MessageEntry extends TimelineEntry {
  const MessageEntry(this.message);

  final ChatMessage message;
}

/// A component in the timeline.
class ComponentEntry extends TimelineEntry {
  const ComponentEntry(this.shown);

  final ShownComponent shown;
}

/// Everything the chat panel renders, plus the turn's status.
class ChatState {
  const ChatState({
    this.timeline = const [],
    this.activeTool,
    this.busy = false,
    this.policyFlags = const [],
    this.guardNote,
    this.error,
    this.ready = false,
    this.turnStartedAt,
  });

  final List<TimelineEntry> timeline;

  /// The tool running right now, for the status row.
  final String? activeTool;

  /// True while a turn is in progress.
  final bool busy;

  /// Sales-language or pressure patterns the policy check found in the last
  /// reply; shown as a banner, never silently edited.
  final List<PolicyFlag> policyFlags;

  /// Why the narration guard replaced the last reply, if it did.
  final String? guardNote;
  final String? error;

  /// True once a driver and pipeline exist; the input is enabled.
  final bool ready;

  /// When the current turn began; null when idle. The panel shows elapsed time.
  final DateTime? turnStartedAt;

  List<ChatMessage> get messages => [
    for (final e in timeline)
      if (e is MessageEntry) e.message,
  ];

  /// The last thing the person said, or an empty string before the first turn.
  String get lastUserText =>
      messages.where((m) => m.role == MessageRole.user).lastOrNull?.text ?? '';

  /// True while a choice or form (other than the app-owned filters card) is
  /// waiting for an answer.
  bool get hasPendingPrompt => timeline.any(
    (e) =>
        e is ComponentEntry &&
        e.shown.request.component.isInteraction &&
        e.shown.request.component.id != 'search_filters' &&
        !e.shown.answered,
  );

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
    DateTime? turnStartedAt,
    bool clearTurnStartedAt = false,
  }) => ChatState(
    timeline: timeline ?? this.timeline,
    activeTool: clearActiveTool ? null : (activeTool ?? this.activeTool),
    busy: busy ?? this.busy,
    policyFlags: policyFlags ?? this.policyFlags,
    guardNote: clearGuardNote ? null : (guardNote ?? this.guardNote),
    error: clearError ? null : (error ?? this.error),
    ready: ready ?? this.ready,
    turnStartedAt: clearTurnStartedAt ? null : (turnStartedAt ?? this.turnStartedAt),
  );
}
