import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

import 'gemma_bootstrap.dart';
import 'rag_demo/rag_demo_data.dart';
import 'rag_demo/widgets/status_card.dart';
import 'rag_demo/widgets/knowledge_base_section.dart';
import 'rag_demo/widgets/search_section.dart';
import 'rag_demo/widgets/result_card.dart';

/// Get database path - returns virtual path on web, real path on mobile
Future<String> _getDatabasePath(String filename) async {
  if (kIsWeb) {
    return filename;
  } else {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/$filename';
  }
}

class RagDemoScreen extends StatefulWidget {
  const RagDemoScreen({super.key});

  @override
  State<RagDemoScreen> createState() => _RagDemoScreenState();
}

class _RagDemoScreenState extends State<RagDemoScreen> {
  final TextEditingController _searchController = TextEditingController(
    text: 'What is Flutter?',
  );

  /// The active RAG vector-store backend. Switched at runtime via the
  /// SegmentedButton below: `FlutterGemma.reset()` tears down the DI singleton
  /// (and the current store), then [bootstrapGemma] re-initializes with the new
  /// store. The installed embedder + active model survive (they live in the
  /// platform plugin instance + prefs, not the DI singleton).
  RagBackend _ragBackend = RagBackend.sqlite;

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
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _checkEmbeddingModel() async {
    // Check if embedding model is already initialized
    final hasModel =
        FlutterGemmaPlugin.instance.initializedEmbeddingModel != null;

    setState(() {
      _hasEmbeddingModel = hasModel;
      _statusMessage = hasModel
          ? 'Embedding model ready. Initialize VectorStore to begin.'
          : 'WARNING: No embedding model!\n'
                'Please create an embedding model first from the Embedding Models screen.';
    });
  }

  /// Swap the active vector-store backend at runtime. Tears down the current
  /// store + DI singleton via [FlutterGemma.reset], then re-bootstraps with the
  /// new store. The installed embedder + active model survive (held in the
  /// platform plugin instance + prefs, not the DI singleton). The switch resets
  /// the demo to an uninitialized state — the new store is empty, so the user
  /// re-initializes + re-adds documents.
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

    final previous = _ragBackend;
    try {
      // Close the current store (release its native handle) AND reset the
      // singleton before re-bootstrapping — dispose() does both, so the
      // qdrant-edge shard / sqlite connection isn't leaked.
      await FlutterGemma.dispose();
      await bootstrapGemma(ragBackend: next);

      setState(() {
        _ragBackend = next;
        _isInitialized = false; // user must re-init the (new, empty) store
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
            content: Text('Switching backend resets the knowledge base.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[RagDemo] Error switching backend: $e');
      // The new backend failed AFTER reset(), so the DI singleton is null and
      // every RAG call would now throw "not initialized". Re-bootstrap the
      // PREVIOUS backend so the app stays usable (with a fresh, empty store of
      // the previous type — the prior data is gone with the closed store).
      var recovered = false;
      try {
        await FlutterGemma.dispose();
        await bootstrapGemma(ragBackend: previous);
        recovered = true;
      } catch (e2) {
        debugPrint('[RagDemo] Recovery re-init also failed: $e2');
      }
      setState(() {
        _isLoading = false;
        _isInitialized = false;
        _stats = null;
        _results = [];
        _statusMessage = recovered
            ? 'Failed to switch to ${next.label}: $e\n'
                  'Reverted to ${previous.label} — re-initialize the VectorStore.'
            : 'Failed to switch backend and could not recover: $e\n'
                  'Please restart the app.';
      });
    }
  }

  Future<void> _initializeVectorStore() async {
    if (!_hasEmbeddingModel) {
      _showError('Please install an embedding model first!');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Initializing VectorStore...';
    });

    try {
      // Per-backend storage path: sqlite wants a `.db` FILE, qdrant-edge wants
      // a shard DIRECTORY. RagBackend.storageName encodes the right shape so
      // the two stores never collide on disk.
      final dbPath = await _getDatabasePath(_ragBackend.storageName);
      await FlutterGemmaPlugin.instance.initializeVectorStore(dbPath);

      final stats = await FlutterGemmaPlugin.instance.getVectorStoreStats();

      setState(() {
        _isInitialized = true;
        _stats = stats;
        _statusMessage =
            'VectorStore initialized! ${stats.documentCount} documents stored.';
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[RagDemo] Error initializing VectorStore: $e');
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
      // Collect all content texts
      final contents = sampleDocuments.map((d) => d['content']!).toList();

      // Batch embedding - one call instead of multiple
      final embeddingModel =
          FlutterGemmaPlugin.instance.initializedEmbeddingModel!;
      final embeddings = await embeddingModel.generateEmbeddings(
        contents,
        taskType: TaskType.retrievalDocument,
      );

      // Add documents with pre-computed embeddings. The `category` is
      // serialised into the payload so the search step can filter on it via
      // qdrant-edge's `Filter` DSL.
      for (int i = 0; i < sampleDocuments.length; i++) {
        final category = sampleDocuments[i]['category'] ?? 'general';
        await FlutterGemmaPlugin.instance.addDocumentWithEmbedding(
          id: sampleDocuments[i]['id']!,
          content: sampleDocuments[i]['content']!,
          embedding: embeddings[i],
          metadata: jsonEncode({'category': category}),
        );
      }

      stopwatch.stop();

      final stats = await FlutterGemmaPlugin.instance.getVectorStoreStats();

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
      await FlutterGemmaPlugin.instance.clearVectorStore();

      final stats = await FlutterGemmaPlugin.instance.getVectorStoreStats();

      setState(() {
        _stats = stats;
        _results = [];
        _statusMessage = 'All documents cleared';
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[RagDemo] Error clearing documents: $e');
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
      // Build payload predicate from the selected category. `null` means no
      // filter — qdrant-edge returns the global top-K.
      final category = _categoryFilter;
      final filter = category == null
          ? null
          : Filter(
              must: [FieldEquals(key: 'category', value: category)],
            );

      final results = await FlutterGemmaPlugin.instance.searchSimilar(
        query: query,
        topK: _topK,
        threshold: _threshold,
        filter: filter,
      );

      stopwatch.stop();

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
            // Runtime vector-store switcher: SQLite <-> Qdrant. Qdrant is
            // native-only, so its segment is disabled on web (with a tooltip).
            // Switching calls FlutterGemma.reset() + re-bootstraps with the new
            // store while preserving the installed embedder + active model.
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
                    : _initializeVectorStore,
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
              // Payload Filter chips — demonstrates qdrant-edge's Filter DSL.
              // Selecting a category constrains the next search to docs whose
              // payload metadata matches `category == <selected>`. On the
              // legacy backend / Web the filter is silently ignored.
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Search Filter (qdrant-edge payload Filter)',
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
