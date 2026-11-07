import 'package:flutter/material.dart';
import '../models/message_model.dart';
import '../services/cloud_ai_service.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <ChatMessage>[];

  bool _isGenerating = false;
  bool _isInitializing = true;
  final String _statusMessage = 'Connecting to cloud AI...';

  late final CloudAIService _service;

  DateTime _lastUiUpdate = DateTime.now();
  static const _uiUpdateInterval = Duration(milliseconds: 50);

  @override
  void initState() {
    super.initState();
    _service = CloudAIService();
    _initService();
  }

  Future<void> _initService() async {
    try {
      await _service.initialize();
    } catch (e) {
      debugPrint('Cloud service init failed: $e');
    }
    if (mounted) setState(() => _isInitializing = false);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _service.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isGenerating) return;

    _controller.clear();

    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true));
      _messages.add(ChatMessage(text: '', isUser: false));
      _isGenerating = true;
    });
    _scrollToBottom();

    try {
      final buffer = StringBuffer();
      _lastUiUpdate = DateTime.now();

      await for (final chunk in _service.generateResponseStream(text)) {
        buffer.write(chunk);
        final now = DateTime.now();
        if (now.difference(_lastUiUpdate) >= _uiUpdateInterval) {
          _lastUiUpdate = now;
          if (!mounted) return;
          setState(() {
            _messages.last = ChatMessage(
              text: buffer.toString(),
              isUser: false,
            );
          });
          _scrollToBottom();
        }
      }

      if (!mounted) return;
      final responseText = buffer.toString();
      setState(() {
        // An empty but successful reply is shown, not removed below.
        _messages.last = ChatMessage(
          text: responseText.isEmpty ? '(no response)' : responseText,
          isUser: false,
        );
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.last = ChatMessage(text: 'Error: $e', isUser: false);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          if (_messages.isNotEmpty &&
              !_messages.last.isUser &&
              _messages.last.text.isEmpty) {
            _messages.removeLast();
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Chat'), centerTitle: true),
      body: Column(
        children: [
          if (_isInitializing)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(_statusMessage),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Send a message to start chatting',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        MessageBubble(message: _messages[index]),
                  ),
          ),
          if (_isGenerating)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Generating...', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: (_isGenerating || _isInitializing)
                        ? null
                        : _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
