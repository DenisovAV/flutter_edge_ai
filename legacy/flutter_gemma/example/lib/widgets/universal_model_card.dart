import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart';
import 'package:flutter_gemma_example/models/base_model.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/universal_download_screen.dart';
import 'package:flutter_gemma_example/chat_screen.dart';

class UniversalModelCard extends StatefulWidget {
  final BaseModel model;

  const UniversalModelCard({super.key, required this.model});

  @override
  State<UniversalModelCard> createState() => _UniversalModelCardState();
}

class _UniversalModelCardState extends State<UniversalModelCard> {
  late PreferredBackend selectedBackend;

  @override
  void initState() {
    super.initState();
    // Set default backend for inference models
    if (widget.model is InferenceModelInterface) {
      selectedBackend =
          (widget.model as InferenceModelInterface).preferredBackend;
    } else {
      selectedBackend = PreferredBackend.cpu; // Default for embedding models
    }
  }

  // Check if model supports backend switching (only for non-local inference models)
  bool get supportsBothBackends {
    if (widget.model is! InferenceModelInterface) return false;
    final inferenceModel = widget.model as InferenceModelInterface;
    return !inferenceModel.localModel;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.all(16.0),
            title: Text(
              widget.model.displayName,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16.0,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4.0),

                // Backend switcher for inference models that support both
                if (supportsBothBackends) ...[
                  Row(
                    children: [
                      const Text('Backend: ', style: TextStyle(fontSize: 14.0)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(4.0),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<PreferredBackend>(
                            value: selectedBackend,
                            isDense: true,
                            items: const [
                              DropdownMenuItem(
                                value: PreferredBackend.cpu,
                                child: Text(
                                  'CPU',
                                  style: TextStyle(fontSize: 14.0),
                                ),
                              ),
                              DropdownMenuItem(
                                value: PreferredBackend.gpu,
                                child: Text(
                                  'GPU',
                                  style: TextStyle(fontSize: 14.0),
                                ),
                              ),
                            ],
                            onChanged: (PreferredBackend? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  selectedBackend = newValue;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8.0),
                ],

                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 4.0,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12.0),
                      ),
                      child: Text(
                        widget.model.size,
                        style: TextStyle(
                          color: Colors.blue[700],
                          fontWeight: FontWeight.bold,
                          fontSize: 12.0,
                        ),
                      ),
                    ),

                    // Show dimension for embedding models
                    if (widget.model is EmbeddingModelInterface) ...[
                      const SizedBox(width: 8.0),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 4.0,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12.0),
                        ),
                        child: Text(
                          '${(widget.model as EmbeddingModelInterface).dimension}D',
                          style: TextStyle(
                            color: Colors.green[700],
                            fontWeight: FontWeight.bold,
                            fontSize: 12.0,
                          ),
                        ),
                      ),
                    ],

                    // Show capabilities for inference models
                    if (widget.model is InferenceModelInterface) ...[
                      const SizedBox(width: 8.0),
                      ..._buildCapabilityChips(
                        widget.model as InferenceModelInterface,
                      ),
                    ],
                  ],
                ),
              ],
            ),
            trailing: Icon(Icons.arrow_forward_ios, color: Colors.grey[400]),
            onTap: () {
              _navigateToScreen(context);
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCapabilityChips(InferenceModelInterface model) {
    List<Widget> chips = [];

    if (model.supportImage) {
      chips.add(_buildChip('📸', 'Multimodal', Colors.orange));
    }

    if (model.supportsFunctionCalls) {
      chips.add(_buildChip('⚡', 'Functions', Colors.purple));
    }

    if (model.supportsThinking) {
      chips.add(_buildChip('🧠', 'Thinking', Colors.teal));
    }

    return chips;
  }

  Widget _buildChip(String emoji, String label, MaterialColor color) {
    return Container(
      margin: const EdgeInsets.only(right: 4.0),
      padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Text(
        '$emoji $label',
        style: TextStyle(
          color: color[700],
          fontSize: 10.0,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  void _navigateToScreen(BuildContext context) {
    // Use UniversalDownloadScreen for both model types on non-web
    // Use ChatScreen directly on web for inference models
    if (widget.model is InferenceModelInterface && kIsWeb) {
      final inferenceModel = widget.model as Model;
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => ChatScreen(
            model: inferenceModel,
            selectedBackend: selectedBackend,
          ),
        ),
      );
    } else {
      // Use UniversalDownloadScreen for all other cases
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => UniversalDownloadScreen(
            model: widget.model,
            selectedBackend: selectedBackend,
          ),
        ),
      );
    }
  }
}
