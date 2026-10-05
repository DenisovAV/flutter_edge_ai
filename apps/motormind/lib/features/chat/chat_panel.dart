import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    await ref.read(chatServiceProvider.notifier).send(text);
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatServiceProvider);
    final theme = Theme.of(context);

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
                    label: Text(chat.busy ? 'Starting…' : 'Start the advisor'),
                  ),
                )
              : ListView(
                  key: const Key('chat-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (chat.messages.isEmpty)
                      Text(
                        'Tell me about the car you have in mind, or what you can spend each month.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    for (final m in chat.messages) _Bubble(message: m),
                    for (final s in chat.shown)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: ResultCard(
                          shown: s,
                          onChoice: (label) => ref.read(chatServiceProvider.notifier).choose(label),
                        ),
                      ),
                    if (chat.activeTool != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Chip(
                            key: const Key('tool-chip'),
                            avatar: const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            label: Text(chat.activeTool!.replaceAll('_', ' ')),
                          ),
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
                    enabled: chat.ready && !chat.busy,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Type here…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('chat-send'),
                  onPressed: chat.ready && !chat.busy ? _send : null,
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
    if (message.text.isEmpty && message.streaming) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
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
        child: Text(message.text.trim()),
      ),
    );
  }
}
