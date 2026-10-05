import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart';
import 'package:flutter_gemma_example/chat_widget.dart';
import 'package:flutter_gemma_example/loading_widget.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.model = Model.gemma3_1B,
    this.selectedBackend,
  });

  final Model model;
  final PreferredBackend? selectedBackend;

  @override
  ChatScreenState createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  InferenceChat? chat;
  final _messages = <Message>[];
  bool _isModelInitialized = false;
  bool _isInitializing = false; // Protection against concurrent initialization
  bool _isStreaming = false; // Track streaming state
  String? _error;
  int? _downloadPercent;
  Color _backgroundColor = const Color(0xFF0b2351);
  late String _appTitle; // App bar title; tool calls can override after load

  // Toggle for sync/async mode
  bool _useSyncMode = false;

  // Define the tools (order and descriptions must match Colab training!)
  final List<Tool> _tools = [
    const Tool(
      name: 'change_background_color',
      description: 'Changes the app background color',
      parameters: {
        'type': 'object',
        'properties': {
          'color': {
            'type': 'string',
            'description':
                'The color name (red, green, blue, yellow, purple, orange)',
          },
        },
        'required': ['color'],
      },
    ),
    const Tool(
      name: 'change_app_title',
      description: 'Changes the application title text in the AppBar',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'The new title text to display',
          },
        },
        'required': ['title'],
      },
    ),
    const Tool(
      name: 'show_alert',
      description: 'Shows an alert dialog with a custom message and title',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'The title of the alert dialog',
          },
          'message': {
            'type': 'string',
            'description': 'The message content of the alert dialog',
          },
        },
        'required': ['title', 'message'],
      },
    ),
  ];

  @override
  void initState() {
    super.initState();
    _appTitle = widget.model.displayName;
    _initializeModel();
  }

  @override
  void dispose() {
    _isInitializing = false; // Reset initialization flag
    _isModelInitialized = false; // Reset model flag
    super.dispose();
    // No need to call deleteModel - model cleanup handled by model.close() callback
  }

  Future<void> _initializeModel() async {
    if (_isModelInitialized || _isInitializing) {
      debugPrint('[ChatScreen] Already initialized or initializing, skipping');
      return;
    }

    _isInitializing = true;
    debugPrint('[ChatScreen] Starting model initialization...');

    try {
      // Step 1: Install model (Modern API handles already-installed check)
      debugPrint('[ChatScreen] Step 1: Installing model...');

      final installer = FlutterGemma.installModel(
        modelType: widget.model.modelType,
        fileType: widget.model.fileType,
      );

      // Choose source based on the model kind. Built-in OS models (Gemini Nano
      // / Apple Foundation Models) have no file: register the bundled identity
      // so the built-in engine resolves, then make sure the OS model is ready
      // (the download screen normally does this first, but ChatScreen is also
      // reachable directly, so guard here too).
      // The one-call Hugging Face path: no URL, no filename, no backend from
      // this catalogue — `fromHuggingFace(repo)` fetches the repo's manifest,
      // installs the revision-pinned variant and hands back the runtime
      // defaults, which Step 2 then applies verbatim via `defaults:`.
      //
      // Only entries whose repo actually ships a litertlm_manifest.json carry
      // `hfRepo`; everything else keeps the fromNetwork branch below.
      ModelRuntimeDefaults? hfDefaults;

      if (widget.model.hfRepo != null) {
        final installation = await installer
            .fromHuggingFace(widget.model.hfRepo!)
            .withProgress((percent) {
              if (!mounted) return;
              setState(() => _downloadPercent = percent);
            })
            .install();
        hfDefaults = installation.runtime;
      } else if (widget.model.isBuiltIn) {
        await installer.fromBundled(widget.model.filename).withProgress((
          percent,
        ) {
          if (!mounted) return;
          setState(() => _downloadPercent = percent);
        }).install();
        await BuiltInAi.ensureReady();
      } else if (widget.model.localModel) {
        await installer.fromAsset(widget.model.url).withProgress((percent) {
          if (!mounted) return;
          setState(() => _downloadPercent = percent);
        }).install();
      } else {
        // Load token if model needs authentication
        String? token;
        if (widget.model.needsAuth) {
          token = await AuthTokenService.loadToken();
          debugPrint(
            '[ChatScreen] Loaded auth token: ${token != null ? "✅" : "❌"}',
          );
        }

        await installer
            .fromNetwork(widget.model.url, token: token)
            .withProgress((percent) {
              if (!mounted) return;
              setState(() => _downloadPercent = percent);
            })
            .install();
      }

      debugPrint('[ChatScreen] Step 1: Model installed ✅');

      // Step 2: Create model with runtime config
      debugPrint('[ChatScreen] Step 2: Creating InferenceModel...');
      // `defaults:` carries the manifest's own maxTokens/backend for an
      // hfRepo model. An explicit user pick in the backend selector still wins
      // — that is the whole point of the defaults being overridable.
      final model = await FlutterGemma.getActiveModel(
        defaults: hfDefaults,
        maxTokens: hfDefaults == null ? widget.model.maxTokens : null,
        preferredBackend:
            widget.selectedBackend ??
            (hfDefaults == null ? widget.model.preferredBackend : null),
        supportImage: widget.model.supportImage,
        maxNumImages: widget.model.maxNumImages,
        supportAudio: widget.model.supportAudio,
      );
      debugPrint('[ChatScreen] Step 2: InferenceModel created ✅');

      // Step 3: Create chat
      debugPrint('[ChatScreen] Step 3: Creating chat...');
      chat = await model.createChat(
        temperature: widget.model.temperature,
        randomSeed: 1,
        topK: widget.model.topK,
        topP: widget.model.topP,
        tokenBuffer: 256,
        supportImage: widget.model.supportImage,
        supportAudio: widget.model.supportAudio,
        supportsFunctionCalls: widget.model.supportsFunctionCalls,
        tools: _tools,
        isThinking: widget.model.isThinking,
        modelType: widget.model.modelType,
      );
      debugPrint('[ChatScreen] Step 3: Chat created ✅');

      setState(() {
        _isModelInitialized = true;
        _error = null;
      });
      debugPrint('[ChatScreen] Initialization complete ✅');
    } catch (e) {
      debugPrint('[ChatScreen] ❌ Initialization failed: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to initialize model: ${e.toString()}';
          _isModelInitialized = false;
          // Drop the stale percentage — a frozen "63%" claims a download is
          // still running long after it died.
          _downloadPercent = null;
        });
      }
      rethrow;
    } finally {
      _isInitializing = false; // Always reset the flag
    }
  }

  // Helper method to handle function calls with system messages (async version)
  Future<void> _handleFunctionCall(FunctionCallResponse functionCall) async {
    // Set streaming state and show "Calling function..." in one setState
    setState(() {
      _isStreaming = true;
      _messages.add(
        Message.systemInfo(
          text:
              "🔧 Calling: ${functionCall.name}(${functionCall.args.entries.map((e) => '${e.key}: "${e.value}"').join(', ')})",
        ),
      );
    });

    // Small delay to show the calling message
    await Future.delayed(const Duration(milliseconds: 300));

    // 2. Show "Executing function"
    setState(() {
      _messages.add(Message.systemInfo(text: "⚡ Executing function"));
    });

    final toolResponse = await _executeTool(functionCall);

    // 3. Show "Function completed"
    setState(() {
      _messages.add(
        Message.systemInfo(
          text: "✅ Function completed: ${toolResponse['message'] ?? 'Success'}",
        ),
      );
    });

    // Small delay to show completion
    await Future.delayed(const Duration(milliseconds: 300));

    // Send tool response back to the model
    final toolMessage = Message.toolResponse(
      toolName: functionCall.name,
      response: toolResponse,
    );
    await chat?.addQuery(toolMessage);

    // TEMPORARILY use sync response for debugging

    final response = await chat!.generateChatResponse();

    if (response is TextResponse && response.token.isNotEmpty) {
      setState(() {
        _messages.add(Message.text(text: response.token));
      });
    }
    // Note: Empty response is OK - "✅ Function completed" message already shown

    // Reset streaming state when done
    setState(() {
      _isStreaming = false;
    });
  }

  // Main gemma response handler - processes responses from GemmaInputField
  Future<void> _handleGemmaResponse(ModelResponse response) async {
    if (response is FunctionCallResponse) {
      await _handleFunctionCall(response);
    } else if (response is ParallelFunctionCallResponse) {
      for (final call in response.calls) {
        await _handleFunctionCall(call);
      }
    } else if (response is TextResponse) {
      // DEBUG: Track what text we're receiving from GemmaInputField
      setState(() {
        _messages.add(Message.text(text: response.token));
        _isStreaming = false;
      });
    } else {}
  }

  // Function to execute tools
  Future<Map<String, dynamic>> _executeTool(
    FunctionCallResponse functionCall,
  ) async {
    if (functionCall.name == 'change_app_title') {
      final newTitle = functionCall.args['title'] as String?;
      if (newTitle != null && newTitle.isNotEmpty) {
        setState(() {
          _appTitle = newTitle;
        });
        return {
          'status': 'success',
          'message': 'App title changed to "$newTitle"',
        };
      } else {
        return {'error': 'Title cannot be empty'};
      }
    }
    if (functionCall.name == 'change_background_color') {
      final colorName = functionCall.args['color']?.toLowerCase();
      final colorMap = {
        'red': Colors.red,
        'blue': Colors.blue,
        'green': Colors.green,
        'yellow': Colors.yellow,
        'purple': Colors.purple,
        'orange': Colors.orange,
      };
      if (colorMap.containsKey(colorName)) {
        setState(() {
          _backgroundColor = colorMap[colorName]!;
        });
        return {
          'status': 'success',
          'message': 'Background color changed to $colorName',
        };
      } else {
        return {
          'error': 'Color not supported',
          'available_colors': colorMap.keys.toList(),
        };
      }
    }
    if (functionCall.name == 'show_alert') {
      final title = functionCall.args['title'] as String? ?? 'Alert';
      final message =
          functionCall.args['message'] as String? ?? 'No message provided';

      // Show the alert dialog
      await showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );

      return {
        'status': 'success',
        'message': 'Alert dialog shown with title "$title"',
      };
    }
    return {'error': 'Tool not found'};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: 'Back',
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.model.displayName,
              style: const TextStyle(fontSize: 18),
              softWrap: true,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            if (_appTitle != widget.model.displayName)
              Text(
                _appTitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                  fontWeight: FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            if (chat?.supportsImages == true)
              const Text(
                'Image support enabled',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.green,
                  fontWeight: FontWeight.normal,
                ),
              ),
          ],
        ),
        actions: [
          // Sync/Async toggle
          Row(
            children: [
              const Text('Sync', style: TextStyle(fontSize: 12)),
              Switch(
                value: _useSyncMode,
                onChanged: (value) {
                  setState(() {
                    _useSyncMode = value;
                  });
                },
                activeColor: Colors.green,
              ),
            ],
          ),
          // Image support indicator
          if (chat?.supportsImages == true)
            const Padding(
              padding: EdgeInsets.only(right: 16.0),
              child: Icon(Icons.image, color: Colors.green, size: 20),
            ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Image.asset(
              'assets/background.png',
              width: 200,
              height: 200,
            ),
          ),
          _isModelInitialized
              ? Column(
                  children: [
                    if (_error != null) _buildErrorBanner(_error!),
                    if (chat?.supportsImages == true && _messages.isEmpty)
                      _buildImageSupportInfo(),
                    if (widget.model.supportAudio && _messages.isEmpty)
                      _buildAudioSupportInfo(),
                    Expanded(
                      child: ChatListWidget(
                        chat: chat,
                        useSyncMode: _useSyncMode,
                        supportsAudio: widget.model.supportAudio,
                        gemmaHandler: _handleGemmaResponse,
                        messageHandler: (message) {
                          // Handles all message additions to history
                          setState(() {
                            _error = null;
                            _messages.add(message);
                            // Set streaming to true when user sends message
                            _isStreaming = true;
                          });
                        },
                        errorHandler: (err) {
                          setState(() {
                            _error = err;
                            _isStreaming = false; // Reset streaming on error
                          });
                        },
                        messages: _messages,
                        isProcessing: _isStreaming,
                      ),
                    ),
                  ],
                )
              // Initialization failed: show the error, not a frozen
              // percentage. _error is only reachable here — the banner above
              // lives in the initialized branch.
              : _error != null
              ? _buildErrorBanner(_error!)
              : LoadingWidget(
                  message: 'Initializing model',
                  progress:
                      (_downloadPercent != null && _downloadPercent! < 100)
                      ? _downloadPercent
                      : null,
                ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String errorMessage) {
    return Container(
      width: double.infinity,
      color: Colors.red,
      padding: const EdgeInsets.all(8.0),
      child: Text(
        errorMessage,
        style: const TextStyle(color: Colors.white),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildImageSupportInfo() {
    return Container(
      margin: const EdgeInsets.all(16.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1a3a5c),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.green, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Model supports images',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  'Use the 📷 button to add images to your messages',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioSupportInfo() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1a3a5c),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.mic, color: Colors.blue, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Model supports audio',
                  style: TextStyle(
                    color: Colors.blue,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  'Use the 🎤 button to record audio messages',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
