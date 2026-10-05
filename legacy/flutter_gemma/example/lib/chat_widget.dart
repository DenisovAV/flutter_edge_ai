import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/chat_input_field.dart';
import 'package:flutter_gemma_example/chat_message.dart';
import 'package:flutter_gemma_example/gemma_input_field.dart';
import 'package:flutter_gemma_example/thinking_widget.dart';

class ChatListWidget extends StatefulWidget {
  const ChatListWidget({
    required this.messages,
    required this.gemmaHandler,
    required this.messageHandler,
    required this.errorHandler,
    this.chat,
    this.isProcessing = false,
    this.useSyncMode = false,
    this.supportsAudio = false,
    super.key,
  });

  final InferenceChat? chat;
  final List<Message> messages;
  final ValueChanged<ModelResponse>
  gemmaHandler; // Accepts ModelResponse (TextToken | FunctionCall)
  final ValueChanged<Message>
  messageHandler; // Handles all message additions to history
  final ValueChanged<String> errorHandler;
  final bool
  isProcessing; // Indicates if the model is currently processing (including function calls)
  final bool useSyncMode; // Toggle for sync/async mode
  final bool supportsAudio; // Whether the model supports audio input

  @override
  State<ChatListWidget> createState() => _ChatListWidgetState();
}

class _ChatListWidgetState extends State<ChatListWidget> {
  // Current streaming thinking state
  String _currentThinkingContent = '';
  bool _isCurrentThinkingExpanded = false;

  // Expanded state for each thinking widget in history (by message index)
  final Map<int, bool> _thinkingExpandedStates = {};

  void _handleGemmaResponse(ModelResponse response) {
    // Capture thinking content before passing to parent
    if (response is ThinkingResponse) {
      setState(() {
        _currentThinkingContent += response.content;
      });
    }
    widget.gemmaHandler(response);
  }

  void _handleNewMessage(Message message) {
    // Reset current thinking for new conversation
    setState(() {
      _currentThinkingContent = '';
      _isCurrentThinkingExpanded = false;
    });
    widget.messageHandler(message);
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      reverse: true,
      itemCount: widget.messages.length + 3, // +1 for thinking widget
      itemBuilder: (context, index) {
        if (index == 0) {
          // Show GemmaInputField if processing OR last message is from user
          if (widget.isProcessing ||
              (widget.messages.isNotEmpty && widget.messages.last.isUser)) {
            return GemmaInputField(
              chat: widget.chat,
              messages: widget.messages,
              streamHandler: _handleGemmaResponse,
              errorHandler: widget.errorHandler,
              isProcessing: widget.isProcessing,
              useSyncMode: widget.useSyncMode,
              onThinkingCompleted: (String thinkingContent) {
                // Add thinking as special thinking message to history
                if (thinkingContent.isNotEmpty) {
                  debugPrint(
                    'ChatListWidget: Adding thinking as thinking message: ${thinkingContent.length} chars',
                  );
                  final thinkingMessage = Message.thinking(
                    text: thinkingContent,
                  );
                  widget.messageHandler(
                    thinkingMessage,
                  ); // Add to history through message handler

                  setState(() {
                    _currentThinkingContent =
                        ''; // Clear current thinking as it's now in history
                  });
                }
              },
            );
          }
          // Show ChatInputField only when not processing and last message is not from user
          if (widget.messages.isEmpty ||
              (!widget.messages.last.isUser && !widget.isProcessing)) {
            return ChatInputField(
              handleSubmitted: _handleNewMessage,
              supportsImages: widget.chat?.supportsImages ?? false,
              supportsAudio: widget.supportsAudio,
            );
          }
        } else if (index == 1) {
          // Thinking widget - only show current streaming thinking
          if (_currentThinkingContent.isNotEmpty) {
            return ThinkingWidget(
              thinking: ThinkingResponse(_currentThinkingContent),
              isExpanded: _isCurrentThinkingExpanded,
              onToggle: () {
                setState(() {
                  _isCurrentThinkingExpanded = !_isCurrentThinkingExpanded;
                });
              },
            );
          }
          return const SizedBox.shrink();
        } else if (index == 2) {
          return const Divider(height: 1.0);
        } else {
          final messageIndex = index - 3;
          final message = widget.messages.reversed.toList()[messageIndex];

          // If this is a thinking message, show as ThinkingWidget
          if (message.type == MessageType.thinking) {
            final originalMessageIndex =
                widget.messages.length - 1 - messageIndex;
            final isExpanded =
                _thinkingExpandedStates[originalMessageIndex] ?? false;

            return ThinkingWidget(
              thinking: ThinkingResponse(message.text),
              isExpanded: isExpanded,
              onToggle: () {
                setState(() {
                  _thinkingExpandedStates[originalMessageIndex] = !isExpanded;
                });
              },
            );
          }

          // Regular message
          return ChatMessageWidget(message: message);
        }
        return null;
      },
    );
  }
}
