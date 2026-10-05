import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart';
import 'package:flutter_gemma_example/chat_screen.dart';
import 'package:flutter_gemma_example/embedding_test_screen.dart';
import 'package:flutter_gemma_example/models/base_model.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/models/embedding_model.dart'
    as example_embedding_model;
import 'package:flutter_gemma_example/models/translate_model.dart';
import 'package:flutter_gemma_example/services/model_download_service.dart';
import 'package:flutter_gemma_example/services/embedding_download_service.dart';
import 'package:flutter_gemma_example/translate_screen.dart';
import 'package:flutter_gemma_example/utils/gated_model_access_dialog.dart';
import 'package:flutter_gemma_example/utils/storage_quota_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

class UniversalDownloadScreen extends StatefulWidget {
  final BaseModel model;
  final PreferredBackend? selectedBackend;

  /// Called when the model is ready (already installed, or just downloaded) and
  /// the user taps Continue. When provided, it REPLACES the built-in navigation
  /// to ChatScreen / EmbeddingTestScreen / TranslateScreen — the caller decides
  /// what to show next (e.g. the agent demo builds its session in place). The
  /// `context` is this screen's, so the callback can pushReplacement onto it.
  final void Function(BuildContext context)? onReady;

  const UniversalDownloadScreen({
    super.key,
    required this.model,
    this.selectedBackend,
    this.onReady,
  });

  @override
  State<UniversalDownloadScreen> createState() =>
      _UniversalDownloadScreenState();
}

class _UniversalDownloadScreenState extends State<UniversalDownloadScreen> {
  // Services
  ModelDownloadService? _inferenceDownloadService;
  EmbeddingModelDownloadService? _embeddingDownloadService;

  bool needToDownload = true;

  // Progress tracking
  double _progress = 0.0; // For inference models
  double _modelProgress = 0.0; // For embedding models
  double _tokenizerProgress = 0.0; // For embedding models

  String _token = '';
  final TextEditingController _tokenController = TextEditingController();

  /// True for OS built-in models (Gemini Nano / Apple Foundation Models). The OS
  /// owns the weights, so there is no file to download: instead of the network
  /// download service we do an instant bundled install + [BuiltInAi.ensureReady]
  /// and surface [BuiltInAiUnavailableException.message] in the error UI.
  bool get _isBuiltIn =>
      widget.model is Model && (widget.model as Model).isBuiltIn;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _initialize();
  }

  void _initializeServices() {
    // Built-in models use no download service — the OS owns the weights.
    if (_isBuiltIn) return;
    switch (widget.model.kind) {
      case ModelKind.embedding:
        _embeddingDownloadService = EmbeddingModelDownloadService(
          model: widget.model as example_embedding_model.EmbeddingModel,
        );
        break;
      case ModelKind.translation:
        final t = widget.model as TranslateModel;
        _inferenceDownloadService = ModelDownloadService(
          modelUrl: t.url,
          modelFilename: t.filename,
          licenseUrl: t.licenseUrl ?? '',
          modelType: t.modelType,
          fileType: t.fileType,
        );
        break;
      case ModelKind.inference:
        final inferenceModel = widget.model as Model;
        _inferenceDownloadService = ModelDownloadService(
          modelUrl: widget.model.url,
          modelFilename: widget.model.filename,
          licenseUrl: widget.model.licenseUrl ?? '',
          modelType: inferenceModel.modelType,
          fileType: inferenceModel.fileType,
          foreground: inferenceModel.foreground,
        );
        break;
    }
  }

  Future<void> _initialize() async {
    // Built-in models have no token and no file to check for — the "install"
    // is an OS availability probe done on demand via [_installBuiltIn].
    if (_isBuiltIn) {
      setState(() => needToDownload = true);
      return;
    }
    if (widget.model.kind == ModelKind.embedding) {
      _token = await _embeddingDownloadService!.loadToken() ?? '';
    } else {
      _token = await _inferenceDownloadService!.loadToken() ?? '';
    }

    _tokenController.text = _token;
    await _checkModelExistence();
  }

  Future<void> _checkModelExistence() async {
    bool exists;

    if (widget.model.kind == ModelKind.embedding) {
      exists = await _embeddingDownloadService!.checkModelExistence(_token);
    } else {
      exists = await _inferenceDownloadService!.checkModelExistence(_token);
    }

    setState(() {
      needToDownload = !exists;
    });
  }

  /// Built-in OS model "install": no file download — register the bundled
  /// identity so [FlutterGemma.getActiveModel] resolves the built-in engine,
  /// then ask the OS to make the model ready ([BuiltInAi.ensureReady], which
  /// downloads the feature if the OS reports it as downloadable). Availability
  /// failures come back as [BuiltInAiUnavailableException]; surface the message
  /// in the existing error UI.
  Future<void> _installBuiltIn() async {
    final model = widget.model as Model;
    setState(() {
      needToDownload = true;
      _progress = 0.0;
    });
    try {
      await FlutterGemma.installModel(
        modelType: model.modelType,
        fileType: ModelFileType.builtIn,
      ).fromBundled(model.filename).install();
      await BuiltInAi.ensureReady(
        onProgress: (p) => setState(() => _progress = p.toDouble()),
      );
      setState(() {
        needToDownload = false;
        _progress = 100.0;
      });
    } on BuiltInAiUnavailableException catch (e) {
      if (mounted) _showErrorDialog(e.message);
      setState(() {
        needToDownload = true;
        _progress = 0.0;
      });
    } catch (e) {
      await _handleDownloadError(e);
      if (mounted) setState(() => _progress = 0.0);
    }
  }

  Future<void> _saveToken(String token) async {
    if (widget.model.kind == ModelKind.embedding) {
      await _embeddingDownloadService!.saveToken(token);
    } else {
      await _inferenceDownloadService!.saveToken(token);
    }
    await _initialize();
  }

  Future<void> _downloadModel() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (widget.model.needsAuth && _token.isEmpty) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Please set your token first.')),
      );
      return;
    }

    setState(() {
      needToDownload = true;
      _progress = 0.0;
      _modelProgress = 0.0;
      _tokenizerProgress = 0.0;
    });

    try {
      if (widget.model.kind == ModelKind.embedding) {
        await _embeddingDownloadService!.downloadModel(
          widget.model.needsAuth ? _token : '',
          (modelProg, tokenizerProg) {
            setState(() {
              _modelProgress = modelProg;
              _tokenizerProgress = tokenizerProg;
            });
          },
        );

        debugPrint('[UI] Embedding download completed');

        setState(() {
          needToDownload = false;
        });
      } else {
        await _inferenceDownloadService!.downloadModel(
          token: widget.model.needsAuth ? _token : '',
          onProgress: (progress) {
            setState(() {
              _progress = progress;
            });
          },
        );
      }

      setState(() {
        needToDownload = false;
      });
    } catch (e) {
      await _handleDownloadError(e);
    }
  }

  Future<void> _deleteModel() async {
    try {
      if (widget.model.kind == ModelKind.embedding) {
        await _embeddingDownloadService!.deleteModel();
      } else {
        await _inferenceDownloadService!.deleteModel();
      }

      setState(() {
        needToDownload = true;
        _progress = 0.0;
        _modelProgress = 0.0;
        _tokenizerProgress = 0.0;
      });
    } catch (e) {
      await _handleDownloadError(e);
    }
  }

  Future<void> _handleDownloadError(Object error) async {
    if (!mounted) return;
    if (isGatedAccessError(error)) {
      await showGatedModelAccessDialog(
        context: context,
        modelUrl: widget.model.url,
        licenseUrl: widget.model.licenseUrl,
        error: error,
      );
    } else if (isStorageQuotaError(error)) {
      await showStorageFullDialog(context);
    } else {
      _showErrorDialog(error.toString());
    }
  }

  void _showErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download Error'),
        content: Text(error),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: Text(widget.model.displayName),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Model info card
            _buildModelInfoCard(),
            const SizedBox(height: 24),

            // Token input (only if auth required)
            if (widget.model.needsAuth) ...[
              _buildTokenInput(),
              const SizedBox(height: 24),
            ],

            // Progress section
            if (needToDownload) _buildProgressSection(),

            // Action buttons
            const SizedBox(height: 24),
            _buildActionButtons(),

            const Spacer(),

            // License info
            if (widget.model.licenseUrl != null) _buildLicenseInfo(),
          ],
        ),
      ),
    );
  }

  Widget _buildModelInfoCard() {
    return Card(
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Model Information',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow('Size:', widget.model.size),
            _buildInfoRow('Type:', _kindLabel(widget.model.kind)),
            if (widget.model.kind == ModelKind.embedding) ...[
              _buildInfoRow(
                'Dimension:',
                '${(widget.model as example_embedding_model.EmbeddingModel).dimension}D',
              ),
            ] else if (widget.model.kind == ModelKind.inference) ...[
              if ((widget.model as InferenceModelInterface).supportImage)
                _buildInfoRow('Multimodal:', 'Yes'),
              if ((widget.model as InferenceModelInterface)
                  .supportsFunctionCalls)
                _buildInfoRow('Functions:', 'Yes'),
              if ((widget.model as InferenceModelInterface).supportsThinking)
                _buildInfoRow('Thinking:', 'Yes'),
            ] else if (widget.model.kind == ModelKind.translation) ...[
              _buildInfoRow('Task:', 'Single-shot translation'),
            ],
          ],
        ),
      ),
    );
  }

  String _kindLabel(ModelKind kind) {
    switch (kind) {
      case ModelKind.inference:
        return 'Inference Model';
      case ModelKind.embedding:
        return 'Embedding Model';
      case ModelKind.translation:
        return 'Translation Model';
    }
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(color: Colors.white)),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressSection() {
    if (widget.model.kind == ModelKind.embedding) {
      return _buildDualProgressBars();
    } else {
      return _buildSingleProgressBar();
    }
  }

  Widget _buildSingleProgressBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Download Progress',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: _progress / 100,
          backgroundColor: Colors.white30,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
        ),
        const SizedBox(height: 8),
        Text(
          '${_progress.toStringAsFixed(1)}%',
          style: const TextStyle(color: Colors.white),
        ),
      ],
    );
  }

  Widget _buildDualProgressBars() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Download Progress',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),

        // Model progress
        Text(
          'Model (${widget.model.size})',
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _modelProgress / 100,
          backgroundColor: Colors.white30,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
        ),
        const SizedBox(height: 4),
        Text(
          '${_modelProgress.toStringAsFixed(1)}%',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),

        const SizedBox(height: 16),

        // Tokenizer progress
        const Text(
          'Tokenizer (~2MB)',
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _tokenizerProgress / 100,
          backgroundColor: Colors.white30,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
        ),
        const SizedBox(height: 4),
        Text(
          '${_tokenizerProgress.toStringAsFixed(1)}%',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),

        const SizedBox(height: 16),

        // Overall progress
        Row(
          children: [
            const Text(
              'Overall: ',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '${((_modelProgress + _tokenizerProgress) / 2).toStringAsFixed(1)}%',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    // Built-in models: the primary action is "Enable" (an OS availability
    // probe + optional feature download), not a file download, and there is no
    // deletable file so the Delete button is suppressed.
    final onPrimary = needToDownload
        ? (_isBuiltIn ? _installBuiltIn : _downloadModel)
        : _proceedToNextScreen;
    final primaryLabel = needToDownload
        ? (_isBuiltIn ? 'Enable' : 'Download')
        : 'Continue';
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1a4a7c),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: Text(primaryLabel),
          ),
        ),
        const SizedBox(width: 12),
        if (!needToDownload && !_isBuiltIn)
          ElevatedButton(
            onPressed: _deleteModel,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            ),
            child: const Text('Delete'),
          ),
      ],
    );
  }

  Widget _buildLicenseInfo() {
    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.white, fontSize: 12),
        children: [
          const TextSpan(text: 'By downloading this model, you agree to the '),
          TextSpan(
            text: 'license terms',
            style: TextStyle(
              color: Colors.blue[300],
              decoration: TextDecoration.underline,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () async {
                if (widget.model.licenseUrl != null) {
                  final uri = Uri.parse(widget.model.licenseUrl!);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  }
                }
              },
          ),
        ],
      ),
    );
  }

  void _proceedToNextScreen() async {
    // A caller-supplied onReady replaces the built-in per-kind navigation.
    if (widget.onReady != null) {
      widget.onReady!(context);
      return;
    }
    switch (widget.model.kind) {
      case ModelKind.embedding:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => EmbeddingTestScreen(
              model: widget.model as example_embedding_model.EmbeddingModel,
            ),
          ),
        );
        break;
      case ModelKind.translation:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                TranslateScreen(model: widget.model as TranslateModel),
          ),
        );
        break;
      case ModelKind.inference:
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (context) => ChatScreen(
              model: widget.model as Model,
              selectedBackend:
                  widget.selectedBackend ??
                  (widget.model as Model).preferredBackend,
            ),
          ),
        );
        break;
    }
  }

  Widget _buildTokenInput() {
    return Card(
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'HuggingFace Access Token',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Paste your Hugging Face access token here',
                hintStyle: const TextStyle(color: Colors.white60),
                border: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white30),
                ),
                enabledBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white30),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.blue),
                ),
                filled: true,
                fillColor: const Color(0xFF2a4a6c),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.save, color: Colors.white),
                  onPressed: () async {
                    final token = _tokenController.text.trim();
                    if (token.isNotEmpty) {
                      final messenger = ScaffoldMessenger.of(context);
                      await _saveToken(token);
                      if (context.mounted) {
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('Access Token saved successfully!'),
                          ),
                        );
                      }
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            RichText(
              text: TextSpan(
                style: const TextStyle(color: Colors.white, fontSize: 12),
                children: [
                  const TextSpan(
                    text: 'To create an access token, please visit ',
                    style: TextStyle(color: Colors.white),
                  ),
                  TextSpan(
                    text: 'https://huggingface.co/settings/tokens',
                    style: TextStyle(
                      color: Colors.blue[300],
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () async {
                        final uri = Uri.parse(
                          'https://huggingface.co/settings/tokens',
                        );
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri);
                        }
                      },
                  ),
                  const TextSpan(
                    text: '. Make sure to give read-repo access to the token.',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }
}
