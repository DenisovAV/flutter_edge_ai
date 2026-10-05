import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'loading_widget.dart';
import 'models/translate_model.dart';
import 'services/auth_token_service.dart';
import 'translation/translate_runner.dart';

/// Translator UI: source/target language pickers, multiline input,
/// streaming output. Re-runs `installModel().fromNetwork()` (idempotent)
/// before `getActiveModel()` and drives `TranslateRunner` for each
/// invocation.
class TranslateScreen extends StatefulWidget {
  const TranslateScreen({super.key, required this.model});

  final TranslateModel model;

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> {
  static const Color _bg = Color(0xFF0b2351);
  static const Color _surface = Color(0xFF1a4a7c);
  static const Color _surfaceAlt = Color(0xFF2a5a8c);

  final TextEditingController _input = TextEditingController();
  String _output = '';
  bool _isInitializing = false;
  bool _isModelInitialized = false;
  bool _translating = false;
  String? _error;
  InferenceModel? _inference;
  TranslateRunner? _runner;
  int? _downloadPercent;

  String _src = 'en';
  String _dst = 'fr';

  @override
  void initState() {
    super.initState();
    final supported = widget.model.promptStrategy.supportedLanguages;
    if (!supported.containsKey(_src)) _src = supported.keys.first;
    if (!supported.containsKey(_dst)) {
      _dst = supported.keys.length > 1
          ? supported.keys.elementAt(1)
          : supported.keys.first;
    }
    _initializeModel();
  }

  @override
  void dispose() {
    _input.dispose();
    // dispose() is sync; surface any cleanup error to the debug log
    // instead of letting it land in the unhandled-async-error zone.
    _inference?.close().catchError((Object e, StackTrace st) {
      debugPrint('[TranslateScreen] dispose close failed: $e\n$st');
    });
    super.dispose();
  }

  Future<void> _initializeModel() async {
    if (_isModelInitialized || _isInitializing) return;
    _isInitializing = true;

    try {
      if (kDebugMode) {
        debugPrint('[TranslateScreen] Installing ${widget.model.filename}…');
      }

      String? token;
      if (widget.model.needsAuth) {
        token = await AuthTokenService.loadToken();
      }

      await FlutterGemma.installModel(
        modelType: widget.model.modelType,
        fileType: widget.model.fileType,
      ).fromNetwork(widget.model.url, token: token).withProgress((percent) {
        if (!mounted) return;
        setState(() => _downloadPercent = percent);
      }).install();

      if (kDebugMode) {
        debugPrint('[TranslateScreen] Model installed, getting active…');
      }

      final model = await FlutterGemma.getActiveModel(
        maxTokens: widget.model.maxTokens,
        preferredBackend: widget.model.preferredBackend,
      );

      if (!mounted) {
        await model.close();
        return;
      }

      setState(() {
        _inference = model;
        _runner = TranslateRunner(
          model: model,
          strategy: widget.model.promptStrategy,
        );
        _isModelInitialized = true;
        _error = null;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TranslateScreen] Initialization failed: $e');
      }
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load model: $e';
      });
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _runTranslate() async {
    final runner = _runner;
    if (runner == null) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _translating = true;
      _output = '';
      _error = null;
    });
    try {
      await for (final chunk in runner.translateStream(
        text: text,
        src: _src,
        dst: _dst,
      )) {
        if (!mounted) return;
        setState(() => _output += chunk);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Translation failed: $e');
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  void _swap() {
    setState(() {
      final tmp = _src;
      _src = _dst;
      _dst = tmp;
    });
  }

  void _copyOutput() {
    Clipboard.setData(ClipboardData(text: _output));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Translation copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supported = widget.model.promptStrategy.supportedLanguages;
    final entries = supported.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: Text(widget.model.displayName),
      ),
      body: !_isModelInitialized
          ? (_error != null
                ? _buildErrorState(_error!)
                : LoadingWidget(
                    message: 'Initializing translation model',
                    progress:
                        (_downloadPercent != null && _downloadPercent! < 100)
                        ? _downloadPercent
                        : null,
                  ))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _langPicker(
                          entries,
                          _src,
                          (v) => setState(() => _src = v),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.swap_horiz, color: Colors.white),
                        tooltip: 'Swap languages',
                        onPressed: _translating ? null : _swap,
                      ),
                      Expanded(
                        child: _langPicker(
                          entries,
                          _dst,
                          (v) => setState(() => _dst = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _input,
                    minLines: 3,
                    maxLines: 6,
                    enabled: !_translating,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: _surface,
                      labelText: 'Text to translate',
                      labelStyle: TextStyle(color: Colors.white70),
                      border: OutlineInputBorder(),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _translating ? Colors.grey : _surfaceAlt,
                      foregroundColor: Colors.white,
                    ),
                    icon: _translating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.translate),
                    label: Text(_translating ? 'Translating…' : 'Translate'),
                    onPressed: _translating ? null : _runTranslate,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      color: Colors.red,
                      padding: const EdgeInsets.all(8.0),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _surface,
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              child: SelectableText(
                                _output.isEmpty ? '—' : _output,
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                          if (_output.isNotEmpty)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(Icons.copy),
                                label: const Text('Copy'),
                                onPressed: _copyOutput,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildErrorState(String message) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _langPicker(
    List<MapEntry<String, String>> entries,
    String value,
    ValueChanged<String> onChange,
  ) {
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      dropdownColor: _surface,
      style: const TextStyle(color: Colors.white),
      iconEnabledColor: Colors.white,
      decoration: const InputDecoration(
        filled: true,
        fillColor: _surface,
        border: OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      items: [
        for (final e in entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(
              '${e.value} (${e.key})',
              style: const TextStyle(color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _translating
          ? null
          : (v) {
              if (v != null) onChange(v);
            },
    );
  }
}
