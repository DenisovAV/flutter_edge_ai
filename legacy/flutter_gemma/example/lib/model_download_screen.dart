import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart';
import 'package:flutter_gemma_example/chat_screen.dart';
import 'package:flutter_gemma_example/services/model_download_service.dart';
import 'package:flutter_gemma_example/utils/gated_model_access_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/model.dart';

class ModelDownloadScreen extends StatefulWidget {
  final Model model;
  final PreferredBackend? selectedBackend;

  const ModelDownloadScreen({
    super.key,
    required this.model,
    this.selectedBackend,
  });

  @override
  State<ModelDownloadScreen> createState() => _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends State<ModelDownloadScreen> {
  late ModelDownloadService _downloadService;
  bool needToDownload = true;
  double _progress = 0.0; // Track download progress
  bool _downloading = false; // Track active download state
  String _token = ''; // Store the token
  final TextEditingController _tokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _downloadService = ModelDownloadService(
      modelUrl: widget.model.url,
      modelFilename: widget.model.filename,
      licenseUrl: widget.model.licenseUrl,
      modelType: widget.model.modelType,
      fileType: widget.model.fileType,
      foreground: widget.model.foreground,
    );
    _initialize();
  }

  Future<void> _initialize() async {
    _token = await _downloadService.loadToken() ?? '';
    _tokenController.text = _token;
    needToDownload = !(await _downloadService.checkModelExistence(_token));
    setState(() {});
  }

  Future<void> _saveToken(String token) async {
    await _downloadService.saveToken(token);
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
      _downloading = true;
    });

    try {
      await _downloadService.downloadModel(
        token: widget.model.needsAuth
            ? _token
            : '', // Pass token only if needed
        onProgress: (progress) {
          setState(() {
            _progress = progress;
          });
        },
      );
      setState(() {
        needToDownload = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (isGatedAccessError(e)) {
        await showGatedModelAccessDialog(
          context: context,
          modelUrl: widget.model.url,
          licenseUrl: widget.model.licenseUrl,
          error: e,
        );
      } else {
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text('Failed to download the model.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _progress = 0.0;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _deleteModel() async {
    await _downloadService.deleteModel();
    setState(() {
      needToDownload = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Model Download'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          spacing: 16,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Download ${widget.model.name} Model',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            if (widget
                .model
                .needsAuth) // Show token input only if auth is required
              TextField(
                controller: _tokenController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Enter HuggingFace AccessToken',
                  hintText: 'Paste your Hugging Face access token here',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.save),
                    onPressed: () async {
                      final token = _tokenController.text.trim();
                      if (token.isNotEmpty) {
                        await _saveToken(token);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
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
            if (widget.model.needsAuth)
              RichText(
                text: TextSpan(
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  text:
                      'To create an access token, please visit your account settings of huggingface at ',
                  children: [
                    TextSpan(
                      text: 'https://huggingface.co/settings/tokens',
                      style: const TextStyle(
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () {
                          launchUrl(
                            Uri.parse('https://huggingface.co/settings/tokens'),
                          );
                        },
                    ),
                    const TextSpan(
                      style: TextStyle(color: Colors.white, fontSize: 14),
                      text:
                          '. Make sure to give read-repo access to the token.',
                    ),
                  ],
                ),
              ),
            if (widget.model.licenseUrl.isNotEmpty)
              RichText(
                text: TextSpan(
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  text: 'License Agreement: ',
                  children: [
                    TextSpan(
                      text: widget.model.licenseUrl,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () {
                          launchUrl(Uri.parse(widget.model.licenseUrl));
                        },
                    ),
                  ],
                ),
              ),
            Center(
              child: (_progress > 0.0 || _downloading)
                  ? Column(
                      children: [
                        Text(
                          'Download Progress: ${_progress.toStringAsFixed(1)}%',
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _progress > 0.0 ? _progress / 100.0 : null,
                        ),
                      ],
                    )
                  : ElevatedButton(
                      onPressed: !needToDownload
                          ? _deleteModel
                          : _downloadModel,
                      child: Text(!needToDownload ? 'Delete' : 'Download'),
                    ),
            ),
            const Spacer(),
            if (!needToDownload)
              Center(
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute<void>(
                          builder: (context) {
                            return ChatScreen(
                              model: widget.model,
                              selectedBackend: widget.selectedBackend,
                            );
                          },
                        ),
                      );
                    },
                    child: const Text('Use the model in Chat Screen'),
                  ),
                ),
              ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
