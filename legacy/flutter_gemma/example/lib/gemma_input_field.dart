import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/chat_message.dart';
import 'package:flutter_gemma_example/services/gemma_service.dart';
import 'package:flutter_gemma_example/thinking_widget.dart';

class GemmaInputField extends StatefulWidget {
  const GemmaInputField({
    super.key,
    required this.messages,
    required this.streamHandler,
    required this.errorHandler,
    this.chat,
    this.onThinkingCompleted,
    this.isProcessing = false,
    this.useSyncMode = false,
  });

  final InferenceChat? chat;
  final List<Message> messages;
  final ValueChanged<ModelResponse>
  streamHandler; // Returns ModelResponse (tokens or functions)
  final ValueChanged<String> errorHandler;
  final ValueChanged<String>?
  onThinkingCompleted; // Callback for completed thinking content
  final bool isProcessing; // Global processing state from ChatScreen
  final bool useSyncMode; // Toggle for sync/async mode

  @override
  GemmaInputFieldState createState() => GemmaInputFieldState();
}

class GemmaInputFieldState extends State<GemmaInputField> {
  GemmaLocalService? _gemma;
  var _message = const Message(text: '', isUser: false);
  bool _processing = false;
  StreamSubscription<ModelResponse>? _streamSubscription;
  FunctionCallResponse?
  _pendingFunctionCall; // Store function to send in onDone
  ParallelFunctionCallResponse? _pendingParallelCall; // Store parallel calls
  String _thinkingContent = ''; // Accumulate thinking content
  bool _isThinkingExpanded = false; // Thinking block expansion state
  bool _thinkingCompleted = false; // Thinking completed
  ThinkingResponse? _completedThinking; // Store completed thinking

  @override
  void initState() {
    super.initState();
    _gemma = GemmaLocalService(widget.chat!);
    _processMessages();
  }

  @override
  void dispose() {
    debugPrint('GemmaInputField: dispose() called');
    _streamSubscription?.cancel();
    debugPrint('GemmaInputField: StreamSubscription cancelled');
    super.dispose();
  }

  void _stopGeneration() async {
    if (!_processing) return;

    try {
      await widget.chat?.stopGeneration();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Generation stopped'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      final message = e.toString().contains('stop_not_supported')
          ? 'Stop generation not yet supported on this platform'
          : 'Failed to stop generation: $e';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  void _processMessages() async {
    if (_processing) return;

    // DEBUG: Track what we're processing
    final isAfterFunction =
        widget.messages.isNotEmpty && !widget.messages.last.isUser;
    debugPrint(
      '🔵 GemmaInputField: Starting processing - isAfterFunction: $isAfterFunction',
    );

    setState(() {
      _processing = true;
      _message = const Message(text: '', isUser: false);
      _thinkingContent = '';
      _thinkingCompleted = false;
      _completedThinking = null;
      _pendingFunctionCall = null;
      _pendingParallelCall = null;
    });

    try {
      final responseStream = await _gemma?.processMessage(
        widget.messages.last,
        useSyncMode: widget.useSyncMode,
      );

      if (responseStream != null) {
        _streamSubscription = responseStream.listen(
          (response) {
            if (mounted) {
              setState(() {
                if (response is String) {
                  _message = Message(
                    text: '${_message.text}$response',
                    isUser: false,
                  );
                } else if (response is TextResponse) {
                  _message = Message(
                    text: '${_message.text}${response.token}',
                    isUser: false,
                  );
                  // DEBUG: Track text accumulation
                  debugPrint(
                    '📝 GemmaInputField: Text accumulated: "${response.token}" -> total: "${_message.text}"',
                  );
                } else if (response is ThinkingResponse) {
                  _thinkingContent += response.content;
                } else if (response is FunctionCallResponse) {
                  debugPrint(
                    '🔧 GemmaInputField: Function call received: ${response.name}',
                  );
                  _pendingFunctionCall = response;
                  _pendingParallelCall = null;
                } else if (response is ParallelFunctionCallResponse) {
                  debugPrint(
                    '🔧 GemmaInputField: Parallel calls received: ${response.calls.length}',
                  );
                  _pendingParallelCall = response;
                  _pendingFunctionCall = null;
                }
              });
            }
          },
          onError: (error) {
            if (mounted) {
              if (_pendingParallelCall != null) {
                widget.streamHandler(_pendingParallelCall!);
              } else if (_pendingFunctionCall != null) {
                widget.streamHandler(_pendingFunctionCall!);
              } else {
                final text = _message.text.isNotEmpty ? _message.text : '...';
                widget.streamHandler(TextResponse(text));
              }
              widget.errorHandler(error.toString());
              setState(() {
                _processing = false;
              });
            }
          },
          onDone: () {
            debugPrint('🏁 GemmaInputField: Stream completed');
            if (mounted) {
              // Handle thinking completion
              if (_thinkingContent.isNotEmpty) {
                setState(() {
                  _thinkingCompleted = true;
                  _completedThinking = ThinkingResponse(_thinkingContent);
                });
                widget.onThinkingCompleted?.call(_thinkingContent);
              }

              if (_pendingParallelCall != null) {
                debugPrint(
                  '🔧 GemmaInputField: Sending parallel calls: ${_pendingParallelCall!.calls.length}',
                );
                widget.streamHandler(_pendingParallelCall!);
              } else if (_pendingFunctionCall != null) {
                debugPrint(
                  '🔧 GemmaInputField: Sending function call: ${_pendingFunctionCall!.name}',
                );
                widget.streamHandler(_pendingFunctionCall!);
              } else {
                final text = _message.text.isNotEmpty ? _message.text : '...';
                // DEBUG: Track what we're sending to ChatScreen
                debugPrint(
                  '📤 GemmaInputField: Sending final text: "$text" (length: ${text.length})',
                );
                widget.streamHandler(TextResponse(text));
              }
              setState(() {
                _processing = false;
              });
            }
          },
        );
        debugPrint('GemmaInputField: StreamSubscription created and listening');
      } else {
        debugPrint('GemmaInputField: responseStream is null!');
        if (mounted) {
          setState(() {
            _processing = false;
          });
        }
      }
    } catch (e) {
      debugPrint('GemmaInputField: Exception caught: $e');
      if (mounted) {
        widget.errorHandler(e.toString());
        setState(() {
          _processing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Determine whether to show thinking (only if last message is from user)
    final shouldShowThinking =
        widget.messages.isNotEmpty &&
        widget.messages.last.isUser &&
        (_thinkingContent.isNotEmpty || _completedThinking != null);

    // Determine which message to display
    // If processing after function (not from user) - show empty for loading
    final displayMessage =
        widget.isProcessing &&
            (widget.messages.isEmpty || !widget.messages.last.isUser)
        ? const Message(text: '', isUser: false) // Force loading indicator
        : _message; // Regular accumulated message

    return SingleChildScrollView(
      child: Column(
        children: [
          // Show thinking block only if shouldShowThinking
          if (shouldShowThinking) ...[
            if (_thinkingCompleted && _completedThinking != null)
              // Completed thinking block
              ThinkingWidget(
                thinking: _completedThinking!,
                isExpanded: _isThinkingExpanded,
                onToggle: () {
                  setState(() {
                    _isThinkingExpanded = !_isThinkingExpanded;
                  });
                },
              )
            else
              // Thinking in progress
              StreamingThinkingWidget(
                content: _thinkingContent,
                isExpanded: _isThinkingExpanded,
                onToggle: () {
                  setState(() {
                    _isThinkingExpanded = !_isThinkingExpanded;
                  });
                },
              ),
          ],
          // Main message with correct content
          ChatMessageWidget(message: displayMessage),
          // Stop generation button
          if (_processing) _buildStopButton(),
        ],
      ),
    );
  }

  Widget _buildStopButton() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: ElevatedButton.icon(
        onPressed: _stopGeneration,
        icon: const Icon(Icons.stop, size: 18, color: Colors.white),
        label: const Text(
          'Stop Generation',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1a4a7c),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}
