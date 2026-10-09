import 'package:flutter/material.dart';
import 'package:genkit/genkit.dart';

import '../models/message_model.dart';
import '../services/ai_engine.dart';
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
  double _downloadProgress = 0;
  String _statusMessage = 'Initializing...';

  late final AiEngine _engine;

  PolicyMode _policy = PolicyMode.cloud;

  // Throttle setState during token streaming to avoid rebuilding on every token.
  DateTime _lastUiUpdate = DateTime.now();
  static const _uiUpdateInterval = Duration(milliseconds: 50);

  @override
  void initState() {
    super.initState();
    _engine = AiEngine();
    _initServices();
  }

  Future<void> _initServices() async {
    try {
      if (mounted) {
        setState(() => _statusMessage = 'Downloading local model...');
      }
      await _engine.initialize(
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p / 100);
        },
      );
    } catch (e) {
      debugPrint('AiEngine init failed: $e');
    }

    if (!mounted) return;
    final defaultPolicy = switch ((_engine.cloudReady, _engine.localReady)) {
      (true, _) => PolicyMode.cloud,
      (false, true) => PolicyMode.local,
      _ => PolicyMode.cloud,
    };
    final parts = [
      if (_engine.cloudReady) 'cloud',
      if (_engine.localReady) 'local',
    ];
    setState(() {
      _isInitializing = false;
      _policy = defaultPolicy;
      _statusMessage = parts.isEmpty
          ? 'No services available'
          : '${parts.join(', ')} ready';
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _engine.dispose();
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

    var generationSucceeded = false;
    try {
      final userMessage = Message(
        role: Role.user,
        content: [TextPart(text: text)],
      );

      final buffer = StringBuffer();
      _lastUiUpdate = DateTime.now();

      // Captured before the call: genkit_hybrid doesn't report which branch
      // actually ran, so this is a best-effort demo counter, not an exact
      // count of cloud calls — see the accounting comment below.
      final wasBudgetAvailable = _engine.budgetAvailable;

      final stream = _engine.ai.generateStream(
        model: _engine.modelFor(_policy),
        messages: [userMessage],
      );
      await for (final chunk in stream) {
        buffer.write(chunk.text);
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
      // genkit 1.0 ends the stream normally when the model fails or the
      // reply is blocked, and reports it in the result, so surface it as an error here.
      final result = await stream.onResult;
      final reason = result.finishReason;
      if (reason != FinishReason.stop &&
          reason != FinishReason.length &&
          reason != FinishReason.unknown) {
        throw result.cause ??
            StateError(result.finishMessage ?? 'The model stopped: $reason');
      }
      generationSucceeded = true;

      // Best-effort demo counter for CostStrategy: genkit_hybrid exposes no
      // "which branch ran" signal, so a Budget call that transiently fell
      // back to on-device still counts here as spent; Budget stops climbing
      // once the cap is hit either way.
      if (_policy == PolicyMode.cloud) {
        _engine.cloudCallsSpent++;
      } else if (_policy == PolicyMode.budget && wasBudgetAvailable) {
        _engine.cloudCallsSpent++;
      }

      if (!mounted) return;
      final responseText = buffer.toString();
      setState(() {
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
          // Clean up the placeholder only when generation neither succeeded
          // nor errored (e.g. interrupted before either branch above ran) —
          // a successful-but-empty response is shown as '(no response)'
          // above instead of silently vanishing here.
          if (!generationSucceeded &&
              _messages.isNotEmpty &&
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: DropdownButton<PolicyMode>(
              value: _policy,
              isExpanded: true,
              items: [
                for (final mode in PolicyMode.values)
                  DropdownMenuItem(
                    value: mode,
                    enabled: mode.availableWith(
                      cloud: _engine.cloudReady,
                      local: _engine.localReady,
                    ),
                    child: Text(mode.label),
                  ),
              ],
              onChanged: (m) {
                if (m != null) setState(() => _policy = m);
              },
            ),
          ),
          if (_isInitializing)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(_statusMessage),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _downloadProgress > 0 ? _downloadProgress : null,
                  ),
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
