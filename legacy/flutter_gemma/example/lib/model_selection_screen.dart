import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart';
import 'package:flutter_gemma_example/chat_screen.dart';
import 'package:flutter_gemma_example/model_download_screen.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/universal_download_screen.dart';

bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

enum SortType {
  defaultOrder('Default'),
  alphabetical('Alphabetical'),
  size('Size');

  const SortType(this.displayName);
  final String displayName;
}

class ModelSelectionScreen extends StatefulWidget {
  /// When set, the screen is in "pick a model" mode: tapping an entry invokes
  /// this and pops (returning the choice to the caller, e.g.
  /// `VoiceSetupScreen`) instead of navigating into the download/chat flow.
  final ValueChanged<Model>? onSelected;

  /// Optional eligibility filter — when set, only models satisfying it are
  /// listed. A pick-mode caller whose install path can't handle every catalog
  /// entry uses this to offer only installable models. The Voice Loop LLM step
  /// installs via `installModel(...).fromNetwork(url)` in `VoiceScreen`, which
  /// can handle neither OS built-in models (no file) nor `localModel` asset
  /// entries (their `url` is an `assets/...` path), so it passes
  /// `(m) => !m.isBuiltIn && !m.localModel`.
  final bool Function(Model model)? modelFilter;

  const ModelSelectionScreen({super.key, this.onSelected, this.modelFilter});

  @override
  State<ModelSelectionScreen> createState() => _ModelSelectionScreenState();
}

class _ModelSelectionScreenState extends State<ModelSelectionScreen> {
  SortType selectedSort = SortType.defaultOrder;
  bool showFilters = false;

  // Filter states
  bool filterMultimodal = false;
  bool filterFunctionCalls = false;
  bool filterThinking = false;

  // Convert size string to MB for sorting
  double _sizeToMB(String size) {
    final numStr = size.replaceAll(RegExp(r'[^0-9.]'), '');
    final num = double.tryParse(numStr) ?? 0;

    if (size.toUpperCase().contains('GB')) {
      return num * 1024; // Convert GB to MB
    } else if (size.toUpperCase().contains('TB')) {
      return num * 1024 * 1024; // Convert TB to MB
    }
    return num; // Assume MB if no unit
  }

  List<Model> _sortModels(List<Model> models) {
    switch (selectedSort) {
      case SortType.alphabetical:
        return [...models]
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
      case SortType.size:
        return [...models]
          ..sort((a, b) => _sizeToMB(a.size).compareTo(_sizeToMB(b.size)));
      case SortType.defaultOrder:
        return models; // Keep original order
    }
  }

  List<Model> _filterModels(List<Model> models) {
    return models.where((model) {
      // Feature filters
      if (filterMultimodal && !model.supportImage) return false;
      if (filterFunctionCalls && !model.supportsFunctionCalls) return false;
      if (filterThinking && !model.isThinking) return false;

      return true;
    }).toList();
  }

  void _clearFilters() {
    setState(() {
      filterMultimodal = false;
      filterFunctionCalls = false;
      filterThinking = false;
    });
  }

  String _getModelsWord(int count) {
    if (count == 1) {
      return 'model';
    } else {
      return 'models';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show all models on all platforms
    var models = Model.values.toList();

    // A pick-mode caller restricts the list to models its install path can
    // actually handle (e.g. the Voice Loop LLM step excludes built-in + local
    // asset models it cannot network-install).
    final modelFilter = widget.modelFilter;
    if (modelFilter != null) {
      models = models.where(modelFilter).toList();
    }

    // Platform-filter the OS built-in models: Gemini Nano is Android-only (ML
    // Kit GenAI / AICore), Apple Foundation Models are iOS/macOS-only. Both
    // carry localModel: true (so they escape the web/network filters and stay
    // visible), so gate them here on defaultTargetPlatform. Web never shows
    // either (no built-in AI host on web).
    models = models.where((model) {
      if (!model.isBuiltIn) return true;
      if (kIsWeb) return false;
      final platform = defaultTargetPlatform;
      if (model == Model.geminiNano) {
        return platform == TargetPlatform.android;
      }
      if (model == Model.appleFoundationModels) {
        return platform == TargetPlatform.iOS ||
            platform == TargetPlatform.macOS;
      }
      return true;
    }).toList();

    // On desktop, only show models with desktopUrl (litertlm format required)
    if (_isDesktop) {
      models = models
          .where((model) => model.localModel || model.supportsDesktop)
          .toList();
    }

    // On web, only show models with webUrl or local models
    if (kIsWeb) {
      models = models
          .where((model) => model.localModel || model.webUrl != null)
          .toList();
    }

    // Apply filtering then sorting
    models = _filterModels(models);
    models = _sortModels(models);
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Select a Model'),
        backgroundColor: const Color(0xFF0b2351),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: 'Back',
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Filters section
            Container(
              margin: const EdgeInsets.only(bottom: 16.0),
              child: Column(
                children: [
                  // Filter header
                  InkWell(
                    onTap: () {
                      setState(() {
                        showFilters = !showFilters;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          Icon(
                            showFilters
                                ? Icons.filter_list
                                : Icons.filter_list_outlined,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Filters',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            showFilters ? Icons.expand_less : Icons.expand_more,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Filter options
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: showFilters ? null : 0,
                    child: showFilters
                        ? Container(
                            padding: const EdgeInsets.all(12.0),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1a2951),
                              borderRadius: BorderRadius.circular(8.0),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Features
                                const Text(
                                  'Features:',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    FilterChip(
                                      label: const Text('Multimodal'),
                                      selected: filterMultimodal,
                                      onSelected: (bool selected) {
                                        setState(() {
                                          filterMultimodal = selected;
                                        });
                                      },
                                      selectedColor: Colors.orange[700],
                                      labelStyle: TextStyle(
                                        color: filterMultimodal
                                            ? Colors.white
                                            : null,
                                      ),
                                    ),
                                    FilterChip(
                                      label: const Text('Function Calls'),
                                      selected: filterFunctionCalls,
                                      onSelected: (bool selected) {
                                        setState(() {
                                          filterFunctionCalls = selected;
                                        });
                                      },
                                      selectedColor: Colors.purple[600],
                                      labelStyle: TextStyle(
                                        color: filterFunctionCalls
                                            ? Colors.white
                                            : null,
                                      ),
                                    ),
                                    FilterChip(
                                      label: const Text('Thinking'),
                                      selected: filterThinking,
                                      onSelected: (bool selected) {
                                        setState(() {
                                          filterThinking = selected;
                                        });
                                      },
                                      selectedColor: Colors.indigo[600],
                                      labelStyle: TextStyle(
                                        color: filterThinking
                                            ? Colors.white
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                // Clear filters button
                                Center(
                                  child: TextButton(
                                    onPressed: _clearFilters,
                                    child: const Text(
                                      'Clear Filters',
                                      style: TextStyle(color: Colors.orange),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            // Sort selector
            Container(
              margin: const EdgeInsets.only(bottom: 16.0),
              child: Row(
                children: [
                  const Text(
                    'Sort:',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<SortType>(
                      value: selectedSort,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1a2951),
                      style: const TextStyle(color: Colors.white),
                      icon: const Icon(
                        Icons.arrow_drop_down,
                        color: Colors.white,
                      ),
                      items: SortType.values.map((type) {
                        return DropdownMenuItem<SortType>(
                          value: type,
                          child: Text(type.displayName),
                        );
                      }).toList(),
                      onChanged: (SortType? newValue) {
                        if (newValue != null) {
                          setState(() {
                            selectedSort = newValue;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            // Results counter
            Container(
              margin: const EdgeInsets.only(bottom: 12.0),
              child: Text(
                'Showing ${models.length} ${_getModelsWord(models.length)}',
                style: TextStyle(color: Colors.grey[400], fontSize: 14),
              ),
            ),
            // Models list
            Expanded(
              child: ListView.builder(
                itemCount: models.length,
                itemBuilder: (context, index) {
                  final model = models[index];
                  return ModelCard(model: model, onSelected: widget.onSelected);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ModelCard extends StatefulWidget {
  final Model model;
  final ValueChanged<Model>? onSelected;

  const ModelCard({super.key, required this.model, this.onSelected});

  @override
  State<ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends State<ModelCard> {
  late PreferredBackend selectedBackend;

  @override
  void initState() {
    super.initState();
    selectedBackend = widget.model.preferredBackend;
  }

  // Check if model supports both backends
  bool get supportsBothBackends {
    // Models that have explicit CPU/GPU support
    // For now, we'll allow switching for all models except local ones
    return !widget.model.localModel;
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
                if (supportsBothBackends) ...[
                  // Backend switcher for models that support both
                  Row(
                    children: [
                      const Text(
                        'Backend: ',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 8),
                      SegmentedButton<PreferredBackend>(
                        segments: const [
                          ButtonSegment<PreferredBackend>(
                            value: PreferredBackend.cpu,
                            label: Text('CPU', style: TextStyle(fontSize: 12)),
                          ),
                          ButtonSegment<PreferredBackend>(
                            value: PreferredBackend.gpu,
                            label: Text('GPU', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        selected: {selectedBackend},
                        onSelectionChanged: (Set<PreferredBackend> selection) {
                          setState(() {
                            selectedBackend = selection.first;
                          });
                        },
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          padding: WidgetStateProperty.all(
                            const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 0,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  // Just show the backend for models that don't support switching
                  Text(
                    'Backend: ${widget.model.preferredBackend.name.toUpperCase()}',
                    style: TextStyle(
                      color:
                          widget.model.preferredBackend == PreferredBackend.gpu
                          ? Colors.green[600]
                          : Colors.blue[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 2.0),
                Text(
                  'Size: ${widget.model.size}',
                  style: TextStyle(color: Colors.grey[600]),
                ),
                if (widget.model.supportsFunctionCalls ||
                    widget.model.supportImage ||
                    widget.model.isThinking) ...[
                  const SizedBox(height: 4.0),
                  Wrap(
                    spacing: 4.0,
                    children: [
                      if (widget.model.supportsFunctionCalls)
                        Chip(
                          label: const Text(
                            'Function Calls',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          backgroundColor: Colors.purple[600],
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      if (widget.model.supportImage)
                        Chip(
                          label: const Text(
                            'Multimodal',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          backgroundColor: Colors.orange[700],
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      if (widget.model.isThinking)
                        Chip(
                          label: const Text(
                            'Thinking',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          backgroundColor: Colors.indigo[600],
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ],
              ],
            ),
            trailing: Icon(Icons.arrow_forward_ios, color: Colors.grey[400]),
            onTap: () {
              // Selection mode (e.g. picking the LLM step in VoiceSetupScreen):
              // return the model to the caller instead of navigating into the
              // download/chat flow.
              if (widget.onSelected != null) {
                widget.onSelected!(widget.model);
                Navigator.pop(context);
                return;
              }
              // Built-in OS models: route through the download screen so its
              // builtIn short-circuit runs (instant bundled install +
              // BuiltInAi.ensureReady), surfacing availability errors before
              // chat. They carry localModel: true, so this branch must precede
              // the localModel one below.
              if (widget.model.isBuiltIn) {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => UniversalDownloadScreen(
                      model: widget.model,
                      selectedBackend: selectedBackend,
                    ),
                  ),
                );
              } else if (widget.model.localModel) {
                // Local models don't need download screen - go directly to chat
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => ChatScreen(
                      model: widget.model,
                      selectedBackend: selectedBackend,
                    ),
                  ),
                );
              } else {
                // Network models - show download screen with token input
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => ModelDownloadScreen(
                      model: widget.model,
                      selectedBackend: selectedBackend,
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
