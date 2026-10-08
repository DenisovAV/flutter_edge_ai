import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:genkit/genkit.dart';
import 'package:image_picker/image_picker.dart';
import '../models/message_model.dart';
import '../services/ai_engine.dart';
import '../services/rag_service.dart';
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

  bool _ragReady = false;
  // Set on web only — on-device embeddings need LiteRT.js's WASM runtime,
  // which no published package ships yet (see AiEngine.initialize). Read by
  // the banner in build() so RAG shows as unavailable, not silently absent.
  String? _ragUnavailableReason;

  late final AiEngine _engine;
  RagService? _ragService;

  PolicyMode _policy = PolicyMode.cloud;

  final _picker = ImagePicker();
  Uint8List? _attachedImage;
  String? _attachedMime;

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

    if (_engine.localReady) {
      // Web takes the same path as native: flutter_edge_ai_litertlm
      // ships the LiteRT.js bundle this app copies into web/, and the tokenizer
      // comes from the `embeddingTokenizers:` AiEngine registers. A real
      // failure still surfaces through the banner below rather than leaving
      // RAG silently off.
      try {
        if (mounted) setState(() => _statusMessage = 'Setting up RAG...');
        final rag = RagService(
          ai: _engine.ai,
          embedderName: _engine.embedderName,
        );
        await rag.initialize(
          onStatus: (s) {
            if (mounted) setState(() => _statusMessage = s);
          },
        );
        _ragService = rag;
        _ragReady = true;
      } catch (e) {
        debugPrint('RAG init failed: $e');
        _ragUnavailableReason = '$e';
      }
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
      if (_ragReady) 'RAG',
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
    _ragService?.dispose();
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

  Future<void> _attachImage() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _attachedImage = bytes;
      _attachedMime = picked.mimeType ?? 'image/jpeg';
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isGenerating) return;

    if (_attachedImage != null && _policy.textOnly) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "The on-device model can't see images — switch to Smart or Cloud.",
          ),
        ),
      );
      return;
    }

    _controller.clear();

    setState(() {
      _messages.add(
        ChatMessage(text: text, isUser: true, imageBytes: _attachedImage),
      );
      _messages.add(ChatMessage(text: '', isUser: false));
      _isGenerating = true;
    });
    _scrollToBottom();

    var generationSucceeded = false;
    try {
      final content = <Part>[TextPart(text: text)];
      if (_attachedImage != null) {
        final mime = _attachedMime ?? 'image/jpeg';
        final dataUri = 'data:$mime;base64,${base64Encode(_attachedImage!)}';
        // contentType MUST be set: the on-device plugin drops media without an
        // image/* contentType, and CapabilityStrategy reads it to detect vision.
        content.add(
          MediaPart(
            media: Media(contentType: mime, url: dataUri),
          ),
        );
      }
      final userMessage = Message(role: Role.user, content: content);

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
      // genkit 1.0 ends the stream normally when the model fails and
      // reports the failure in the result, so surface it as an error here.
      final result = await stream.onResult;
      if (result.finishReason == FinishReason.failed) {
        throw result.cause ?? StateError(result.error?.message ?? 'failed');
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
          _attachedImage = null;
          _attachedMime = null;
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
          if (_ragUnavailableReason != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'RAG unavailable: $_ragUnavailableReason',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
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
          if (_attachedImage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      _attachedImage!,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('Image attached', style: TextStyle(fontSize: 12)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _attachedImage = null;
                      _attachedMime = null;
                    }),
                  ),
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
                  IconButton(
                    onPressed: (_isGenerating || _isInitializing)
                        ? null
                        : _attachImage,
                    icon: const Icon(Icons.image_outlined),
                    tooltip: 'Attach image',
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
