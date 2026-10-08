import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../advisor/display_agent.dart';
import '../search/search_service.dart';
import 'chat_service.dart';
import 'result_card.dart';

/// The conversation: transcript, components the model presented, tool status,
/// guard and policy notes, and the input. Lives inside the advisor surface.
class ChatPanel extends ConsumerStatefulWidget {
  const ChatPanel({super.key, required this.header});

  final Widget header;

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(chatServiceProvider).busy) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    final svc = ref.read(chatServiceProvider.notifier);
    // A new prompt during a turn restarts with it (Q58): interrupt, then send.
    if (ref.read(chatServiceProvider).busy) {
      await svc.interrupt();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await svc.send(text);
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  int _lastLen = 0;
  Timer? _ticker;

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatServiceProvider);
    final theme = Theme.of(context);
    if (chat.timeline.length != _lastLen) {
      _lastLen = chat.timeline.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }

    return Column(
      children: [
        widget.header,
        if (chat.policyFlags.isNotEmpty)
          MaterialBanner(
            key: const Key('policy-banner'),
            content: Text(
              'Motormind does not sell or promise. This reply tripped the sales-language check '
              '(${chat.policyFlags.map((f) => f.category.name).toSet().join(', ')}).',
            ),
            leading: const Icon(Icons.flag_outlined),
            actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
          ),
        if (chat.guardNote != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              chat.guardNote!,
              key: const Key('guard-note'),
              style: theme.textTheme.labelSmall,
            ),
          ),
        if (chat.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              chat.error!,
              key: const Key('chat-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Expanded(
          child: !chat.ready
              ? Center(
                  child: FilledButton.icon(
                    key: const Key('chat-start'),
                    onPressed: chat.busy
                        ? null
                        : () => ref.read(chatServiceProvider.notifier).start(),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(chat.busy ? 'Starting…' : 'Ask Motormind'),
                  ),
                )
              : ListView(
                  key: const Key('chat-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final e in chat.timeline)
                      switch (e) {
                        MessageEntry(:final message)
                            when message.role == 'system' &&
                                message.text.startsWith('Looking for') &&
                                !ref.watch(displayProvider).notes =>
                          const SizedBox.shrink(),
                        MessageEntry(:final message) => _Bubble(message: message),
                        ComponentEntry(:final shown) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: ResultCard(
                            shown: shown,
                            onChoice: (id, label) {
                              // A selection sends with whatever was typed (Q60).
                              final extra = _controller.text;
                              _controller.clear();
                              ref
                                  .read(chatServiceProvider.notifier)
                                  .choose(id, label, supplement: extra, source: shown);
                            },
                          ),
                        ),
                      },
                    if (chat.busy && chat.turnStartedAt != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${chat.activeTool == null ? 'Thinking' : chat.activeTool!.replaceAll('_', ' ')} · '
                                '${DateTime.now().difference(chat.turnStartedAt!).inSeconds}s',
                                key: const Key('turn-status'),
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                            IconButton(
                              key: const Key('chat-interrupt'),
                              tooltip: 'Show what you have so far',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => ref.read(chatServiceProvider.notifier).interrupt(),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('chat-input'),
                    controller: _controller,
                    enabled: chat.ready,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: _hint(chat, ref),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('chat-send'),
                  onPressed: chat.ready ? _send : null,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    if (message.role == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(message.text, key: const Key('system-line'), style: theme.textTheme.labelSmall),
      );
    }
    if (message.text.isEmpty && message.streaming) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (message.text.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: isUser ? theme.colorScheme.primaryContainer : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(_plain(message.text)),
      ),
    );
  }
}

/// Small models emit Markdown and escape dollars; bubbles are plain text for
/// now (TQ56), so strip the common markers rather than show them raw.
String _plain(String text) => text
    .replaceAll(r'\$', r'$')
    .replaceAll('**', '')
    .replaceAllMapped(RegExp(r'^\s*[-*]\s+', multiLine: true), (_) => '• ')
    .trim();

/// The input is the escape from any prompt (there is no "something else"
/// chip): the hint says so while a choice or form is live, and invites more
/// once filters exist.
String _hint(ChatState chat, WidgetRef ref) {
  final pending = chat.timeline.any(
    (e) =>
        e is ComponentEntry &&
        e.shown.request.component.isInteraction &&
        e.shown.request.component.id != 'search_filters' &&
        !e.shown.answered,
  );
  if (pending) return 'Something else? Type it here…';
  final search = ref.watch(searchProvider);
  if (!search.query.isEmpty) return 'Tell me more: must-haves, a budget, a trade-in…';
  return 'Tell me about the car you have in mind…';
}
