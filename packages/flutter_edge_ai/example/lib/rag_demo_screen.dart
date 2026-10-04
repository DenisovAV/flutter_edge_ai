import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show FlutterEdgeAi;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'gemma_bootstrap.dart';
import 'rag_demo/rag_demo_data.dart';
import 'rag_demo/rag_storage_location.dart';
import 'rag_demo/widgets/status_card.dart';
import 'rag_demo/widgets/knowledge_base_section.dart';
import 'rag_demo/widgets/search_section.dart';
import 'rag_demo/widgets/result_card.dart';
import 'utils/installed_model_lookup.dart';

class RagDemoScreen extends StatefulWidget {
  const RagDemoScreen({super.key});

  @override
  State<RagDemoScreen> createState() => _RagDemoScreenState();
}

class _RagDemoScreenState extends State<RagDemoScreen> {
  final TextEditingController _searchController = TextEditingController(
    text: 'What is Flutter?',
  );

  /// The active RAG vector-store backend. Switching closes only this screen's
  /// independently-owned [RagIndex]; inference and embedding stay initialized.
  RagBackend _ragBackend = RagBackend.sqlite;
  RagIndex? _index;

  bool _isInitialized = false;
  bool _isLoading = false;
  bool _hasEmbeddingModel = false;
  String _statusMessage = 'Checking embedding model...';
  List<RetrievalResult> _results = [];
  VectorStoreStats? _stats;

  double _threshold = 0.0;
  int _topK = 5;

  int _addTimeMs = 0;
  int _searchTimeMs = 0;

  /// Selected category for the payload-aware `Filter` demo. `null` = no filter
  /// (every document is eligible). Demonstrates qdrant-edge's payload predicate.
  String? _categoryFilter;

  @override
  void initState() {
    super.initState();
    _checkEmbeddingModel();
  }

  @override
  void dispose() {
    final index = _index;
    _index = null;
    if (index != null) {
      // State.dispose cannot await. RagIndex rejects new work immediately and
      // waits for already accepted operations before it closes the store.
      unawaited(
        index.dispose().catchError((Object error, StackTrace stackTrace) {
          debugPrint(
            '[RagDemo] Error closing VectorStore during dispose: $error',
          );
        }),
      );
    }
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _checkEmbeddingModel() async {
    final hasActiveModel = FlutterEdgeAi.activeEmbedderSpec != null;
    final profileId = await activeEmbeddingProfileId();
    final hasKnownProfile = profileId != null;

    if (!mounted) return;
    setState(() {
      _hasEmbeddingModel = hasActiveModel && hasKnownProfile;
      _statusMessage = switch ((hasActiveModel, hasKnownProfile)) {
        (false, _) =>
          'WARNING: No embedding model!\n'
              'Please create one from the Embedding Models screen.',
        (true, false) =>
          'The active embedding model has no stable RAG profile in the '
              'example catalog. Re-select a catalog model before indexing.',
        (true, true) =>
          'Embedding model ready. Initialize VectorStore to begin.',
      };
    });
  }

  /// Swap the active vector-store backend without resetting Flutter Edge AI.
  /// Each backend/profile pair has its own persistent location.
  Future<void> _switchBackend(RagBackend next) async {
    if (next == _ragBackend) return;
    if (!next.isSupportedOnThisPlatform) {
      _showError('${next.label} is not available on web.');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Switching to ${next.label}...';
    });

    try {
      final previousIndex = _index;
      _index = null;
      await previousIndex?.dispose();
      if (!mounted) return;

      setState(() {
        _ragBackend = next;
        _isInitialized = false;
        _stats = null;
        _results = [];
        _categoryFilter = null;
        _addTimeMs = 0;
        _searchTimeMs = 0;
        _statusMessage =
            'Switched to ${next.label}. Initialize VectorStore to begin.';
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Each backend keeps a separate persistent knowledge base.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[RagDemo] Error switching backend: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isInitialized = false;
        _stats = null;
        _results = [];
        _statusMessage =
            'Failed to close the current VectorStore: $e\n'
            'Reopen the RAG screen before continuing.';
      });
    }
  }

  Future<void> _openRagIndex() async {
    if (!_hasEmbeddingModel) {
      _showError('Please install an embedding model first!');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Initializing VectorStore...';
    });

    try {
      final profileId = await activeEmbeddingProfileId();
      if (profileId == null) {
        throw StateError(
          'The active embedder is not a versioned model from the example '
          'catalog. Re-select an embedding model before opening RAG.',
        );
      }
      final location = await resolveRagStorageLocation(
        _ragBackend.storageName(profileId),
      );
      final spec = VectorStoreSpec(
        providerId: _ragBackend.providerId,
        location: location,
        filterSchema: kRagDemoFilterSchema,
      );
      if (!exampleRag.canOpen(spec)) {
        throw UnsupportedError(
          '${_ragBackend.label} is unavailable on this platform.',
        );
      }

      final index = await exampleRag.open(
        spec: spec,
        activeEmbedderProfileId: profileId,
      );
      try {
        final stats = await index.stats();
        if (!mounted) {
          await index.dispose();
          return;
        }

        setState(() {
          _index = index;
          _isInitialized = true;
          _stats = stats;
          _statusMessage =
              'VectorStore initialized! ${stats.documentCount} documents stored.';
          _isLoading = false;
        });
      } catch (_) {
        await index.dispose();
        rethrow;
      }
    } catch (e) {
      debugPrint('[RagDemo] Error initializing VectorStore: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error initializing VectorStore: $e';
      });
    }
  }

  Future<void> _addDocuments() async {
    if (!_isInitialized) {
      _showError('Please initialize VectorStore first!');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Adding documents...';
    });

    final stopwatch = Stopwatch()..start();

    try {
      final index = _index;
      if (index == null) throw StateError('RAG index is not open.');

      // The index borrows the active embedder and applies the document task
      // prefix. `category` is promoted through the declared FilterSchema.
      for (int i = 0; i < sampleDocuments.length; i++) {
        final category = sampleDocuments[i]['category'] ?? 'general';
        await index.addText(
          id: sampleDocuments[i]['id']!,
          content: sampleDocuments[i]['content']!,
          metadata: jsonEncode({'category': category}),
        );
      }
      await index.flush();

      stopwatch.stop();

      final stats = await index.stats();

      if (!mounted) return;
      setState(() {
        _stats = stats;
        _addTimeMs = stopwatch.elapsedMilliseconds;
        _statusMessage =
            'Added ${sampleDocuments.length} documents in ${_addTimeMs}ms';
        _isLoading = false;
      });
    } catch (e) {
      stopwatch.stop();
      debugPrint('[RagDemo] Error adding documents: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error adding documents: $e';
      });
    }
  }

  Future<void> _clearDocuments() async {
    if (!_isInitialized) {
      _showError('Please initialize VectorStore first!');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Clearing documents...';
    });

    try {
      final index = _index;
      if (index == null) throw StateError('RAG index is not open.');
      await index.clear();

      final stats = await index.stats();

      if (!mounted) return;
      setState(() {
        _stats = stats;
        _results = [];
        _statusMessage = 'All documents cleared';
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[RagDemo] Error clearing documents: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error clearing documents: $e';
      });
    }
  }

  Future<void> _search() async {
    if (!_isInitialized) {
      _showError('Please initialize VectorStore first!');
      return;
    }

    final query = _searchController.text.trim();
    if (query.isEmpty) {
      _showError('Please enter a search query');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Searching...';
    });

    final stopwatch = Stopwatch()..start();

    try {
      final index = _index;
      if (index == null) throw StateError('RAG index is not open.');

      // Build a backend-independent payload predicate. `null` means no filter.
      final category = _categoryFilter;
      final filter = category == null
          ? null
          : Filter(
              must: [FieldEquals(key: 'category', value: category)],
            );

      final results = await index.searchText(
        query: query,
        topK: _topK,
        threshold: _threshold,
        filter: filter,
      );

      stopwatch.stop();

      if (!mounted) return;
      setState(() {
        _results = results;
        _searchTimeMs = stopwatch.elapsedMilliseconds;
        final filterDesc = _categoryFilter == null
            ? 'no filter'
            : 'category=$_categoryFilter';
        _statusMessage =
            'Found ${results.length} results in ${_searchTimeMs}ms ($filterDesc)';
        _isLoading = false;
      });
    } catch (e) {
      stopwatch.stop();
      debugPrint('[RagDemo] Search error: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = 'Search error: $e';
      });
    }
  }

  void _showError(String message) {
    debugPrint('[RagDemo] ERROR: $message');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// Runtime backend switcher. A [SegmentedButton] over [RagBackend]. The
  /// qdrant segment is disabled where it's unsupported (web) and wrapped in a
  /// [Tooltip] explaining why. The whole control is disabled while loading.
  Widget _buildBackendSwitcher() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_horiz, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Vector Store: ${_ragBackend.label}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<RagBackend>(
              segments: [
                for (final backend in RagBackend.values)
                  ButtonSegment<RagBackend>(
                    value: backend,
                    enabled: backend.isSupportedOnThisPlatform,
                    label: backend.isSupportedOnThisPlatform
                        ? Text(backend.label)
                        : Tooltip(
                            message:
                                'Qdrant is native-only (Android/iOS/desktop)',
                            child: Text(backend.label),
                          ),
                  ),
              ],
              selected: {_ragBackend},
              onSelectionChanged: _isLoading
                  ? null
                  : (selection) => _switchBackend(selection.first),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RAG Demo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Runtime vector-store switcher: SQLite <-> Qdrant. Provider probes
            // disable unsupported choices without an app-level platform branch.
            // Switching closes only this screen's independently-owned index.
            _buildBackendSwitcher(),
            const SizedBox(height: 16),

            StatusCard(
              hasEmbeddingModel: _hasEmbeddingModel,
              statusMessage: _statusMessage,
              stats: _stats,
            ),
            const SizedBox(height: 16),

            // Initialize Button
            if (!_isInitialized)
              ElevatedButton.icon(
                onPressed: _isLoading || !_hasEmbeddingModel
                    ? null
                    : _openRagIndex,
                icon: _isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.storage),
                label: const Text('Initialize VectorStore'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),

            if (_isInitialized) ...[
              // Payload Filter chips — shared by both storage providers.
              // Selecting a category constrains the next search to docs whose
              // payload metadata matches `category == <selected>`.
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Search Filter (portable payload Filter)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('All'),
                            selected: _categoryFilter == null,
                            onSelected: (selected) {
                              if (selected) {
                                setState(() => _categoryFilter = null);
                              }
                            },
                          ),
                          for (final cat in sampleCategories)
                            ChoiceChip(
                              label: Text('category = $cat'),
                              selected: _categoryFilter == cat,
                              onSelected: (selected) {
                                setState(() {
                                  _categoryFilter = selected ? cat : null;
                                });
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              KnowledgeBaseSection(
                isLoading: _isLoading,
                addTimeMs: _addTimeMs,
                onAddDocuments: _addDocuments,
                onClearDocuments: _clearDocuments,
              ),
              const SizedBox(height: 24),

              SearchSection(
                controller: _searchController,
                threshold: _threshold,
                topK: _topK,
                isLoading: _isLoading,
                searchTimeMs: _searchTimeMs,
                onSearch: _search,
                onThresholdChanged: (value) =>
                    setState(() => _threshold = value),
                onTopKChanged: (value) => setState(() => _topK = value),
              ),
              const SizedBox(height: 24),

              // Results Section
              if (_results.isNotEmpty) ...[
                const Text(
                  'Results',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ..._results.map((result) => ResultCard(result: result)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
