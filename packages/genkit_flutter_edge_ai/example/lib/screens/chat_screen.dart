import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets/message_bubble.dart';
import '../widgets/status_banner.dart';

class ChatScreen extends StatefulWidget {
  final AppState appState;
  final VoidCallback onGoToSettings;

  const ChatScreen({
    super.key,
    required this.appState,
    required this.onGoToSettings,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    widget.appState.sendMessage(text);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final state = widget.appState;

        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

        return Column(
          children: [
            if (!state.inferenceInstalled)
              StatusBanner(
                message: 'Inference model not installed.',
                onAction: widget.onGoToSettings,
              ),

            // Toolbar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  const Text('Streaming'),
                  Switch(
                    value: state.useStreaming,
                    onChanged: state.isGenerating
                        ? null
                        : (v) {
                            state.useStreaming = v;
                          },
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed:
                        state.chatMessages.isEmpty ? null : state.clearChat,
                    tooltip: 'Clear chat',
                  ),
                ],
              ),
            ),

            // Messages
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: state.chatMessages.length +
                    (state.isGenerating && state.currentStreamText.isNotEmpty
                        ? 1
                        : 0),
                itemBuilder: (context, index) {
                  if (index < state.chatMessages.length) {
                    final msg = state.chatMessages[index];
                    return MessageBubble(text: msg.text, isUser: msg.isUser);
                  }
                  // Streaming in-progress bubble
                  return MessageBubble(
                    text: state.currentStreamText,
                    isUser: false,
                  );
                },
              ),
            ),

            // Input
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      enabled: state.inferenceInstalled && !state.isGenerating,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: state.inferenceInstalled && !state.isGenerating
                        ? _send
                        : null,
                    icon: state.isGenerating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
