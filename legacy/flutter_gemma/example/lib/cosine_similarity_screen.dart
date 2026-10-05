import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/models/embedding_model.dart'
    as example_embedding_model;
import 'package:flutter_gemma_example/services/auth_token_service.dart';

class CosineSimilarityScreen extends StatefulWidget {
  final example_embedding_model.EmbeddingModel model;
  final EmbeddingModel? preInitializedModel; // New parameter

  const CosineSimilarityScreen({
    super.key,
    required this.model,
    this.preInitializedModel, // Optional
  });

  @override
  State<CosineSimilarityScreen> createState() => _CosineSimilarityScreenState();
}

class _CosineSimilarityScreenState extends State<CosineSimilarityScreen> {
  // Test sentences
  static const String queryText = "Which planet is known as the Red Planet";
  static const String similarText = "Mars is famous for its reddish appearance";
  static const String differentText = "Pluto is not red";

  EmbeddingModel? _embeddingModel;
  bool _isGenerating = false;
  String? _errorMessage;
  int? _downloadPercent;

  /// Which file the percentage refers to. The model and the tokenizer are
  /// downloaded sequentially into the same counter, so without this the bar
  /// runs 0→100→0 and the label lies during the second phase.
  String _downloadStage = 'model';

  // Embeddings
  List<double>? _queryEmbedding;
  List<double>? _similarEmbedding;
  List<double>? _differentEmbedding;

  // Similarity scores
  double? _querySimilarSimilarity;
  double? _queryDifferentSimilarity;

  @override
  void initState() {
    super.initState();
    _initializeEmbeddingModelIfNeeded();
  }

  @override
  void dispose() {
    // Don't close the model if it was passed from outside
    if (widget.preInitializedModel == null) {
      _embeddingModel?.close();
    }
    super.dispose();
  }

  Future<void> _initializeEmbeddingModelIfNeeded() async {
    // If model is already provided externally, use it
    if (widget.preInitializedModel != null) {
      _embeddingModel = widget.preInitializedModel;
      if (kDebugMode) {
        debugPrint('[CosineSimilarityScreen] Using pre-initialized model ✅');
      }
      setState(() {
        // Model ready
      });
      return;
    }

    // Otherwise install model as before
    try {
      if (kDebugMode) {
        debugPrint('[CosineSimilarityScreen] Installing embedding model...');
      }

      // Load token from AuthTokenService if model requires authentication
      String? token;
      if (widget.model.needsAuth) {
        final authToken = await AuthTokenService.loadToken();
        token = authToken?.isNotEmpty == true ? authToken : null;
        if (kDebugMode) {
          debugPrint(
            '[CosineSimilarityScreen] Using auth token: ${token != null ? "YES" : "NO"}',
          );
        }
      }

      await FlutterGemma.installEmbedder()
          .modelFromNetwork(widget.model.url, token: token)
          .tokenizerFromNetwork(widget.model.tokenizerUrl, token: token)
          .withModelProgress((percent) {
            if (!mounted) return;
            setState(() {
              _downloadStage = 'model';
              _downloadPercent = percent;
            });
          })
          .withTokenizerProgress((percent) {
            if (!mounted) return;
            setState(() {
              _downloadStage = 'tokenizer';
              _downloadPercent = percent;
            });
          })
          .install();

      if (kDebugMode) {
        debugPrint('[CosineSimilarityScreen] Embedding model installed ✅');
      }

      // Get active embedding model
      _embeddingModel = await FlutterGemma.getActiveEmbedder(
        preferredBackend:
            PreferredBackend.gpu, // Use GPU mode for better performance
      );

      if (kDebugMode) {
        debugPrint('[CosineSimilarityScreen] Embedding model ready ✅');
      }

      setState(() {
        // Model initialized successfully
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ Could not create embedding model: $e');
      }
      setState(() {
        _errorMessage = e.toString();
        // Without this the progress card stays on screen forever, contradicting
        // the error card right below it.
        _downloadPercent = null;
      });
    }
  }

  /// Calculate cosine similarity between two vectors
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have the same length');
    }

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA == 0.0 || normB == 0.0) {
      return 0.0;
    }

    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
  }

  Future<void> _generateAndCompare() async {
    if (_embeddingModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Embedding model not initialized'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _errorMessage = null;
      _queryEmbedding = null;
      _similarEmbedding = null;
      _differentEmbedding = null;
      _querySimilarSimilarity = null;
      _queryDifferentSimilarity = null;
    });

    try {
      // Generate embeddings for all three sentences
      if (kDebugMode) {
        debugPrint('Generating query embedding...');
      }
      _queryEmbedding = await _embeddingModel!.generateEmbedding(queryText);

      if (kDebugMode) {
        debugPrint('Generating similar embedding...');
      }
      _similarEmbedding = await _embeddingModel!.generateEmbedding(similarText);

      if (kDebugMode) {
        debugPrint('Generating different embedding...');
      }
      _differentEmbedding = await _embeddingModel!.generateEmbedding(
        differentText,
      );

      // Debug: Print vector info
      if (kDebugMode) {
        debugPrint('📊 DEBUG INFO:');
        debugPrint('Query vector length: ${_queryEmbedding!.length}');
        debugPrint('Similar vector length: ${_similarEmbedding!.length}');
        debugPrint('Different vector length: ${_differentEmbedding!.length}');

        debugPrint(
          'Query first 5 values: ${_queryEmbedding!.take(5).toList()}',
        );
        debugPrint(
          'Similar first 5 values: ${_similarEmbedding!.take(5).toList()}',
        );
        debugPrint(
          'Different first 5 values: ${_differentEmbedding!.take(5).toList()}',
        );

        // Calculate norms
        final queryNorm = math.sqrt(
          _queryEmbedding!.fold<double>(0.0, (sum, val) => sum + val * val),
        );
        final similarNorm = math.sqrt(
          _similarEmbedding!.fold<double>(0.0, (sum, val) => sum + val * val),
        );
        final differentNorm = math.sqrt(
          _differentEmbedding!.fold<double>(0.0, (sum, val) => sum + val * val),
        );

        debugPrint('Query norm: $queryNorm');
        debugPrint('Similar norm: $similarNorm');
        debugPrint('Different norm: $differentNorm');
      }

      // Calculate similarities
      _querySimilarSimilarity = _cosineSimilarity(
        _queryEmbedding!,
        _similarEmbedding!,
      );
      _queryDifferentSimilarity = _cosineSimilarity(
        _queryEmbedding!,
        _differentEmbedding!,
      );

      if (kDebugMode) {
        debugPrint('✅ Query vs Similar: $_querySimilarSimilarity');
        debugPrint('✅ Query vs Different: $_queryDifferentSimilarity');
      }

      setState(() {
        _isGenerating = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Similarity comparison completed!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error generating embeddings: $e');
      }

      setState(() {
        _errorMessage = e.toString();
        _isGenerating = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _clearResults() {
    setState(() {
      _queryEmbedding = null;
      _similarEmbedding = null;
      _differentEmbedding = null;
      _querySimilarSimilarity = null;
      _queryDifferentSimilarity = null;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Cosine Similarity Demo'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Model info
            Card(
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
                    _buildInfoRow('Model:', widget.model.displayName),
                    _buildInfoRow('Dimension:', '${widget.model.dimension}D'),
                    _buildInfoRow('Max Seq Len:', '${widget.model.maxSeqLen}'),
                  ],
                ),
              ),
            ),

            if (_embeddingModel == null &&
                _downloadPercent != null &&
                _errorMessage == null) ...[
              const SizedBox(height: 16),
              _buildDownloadProgressCard(),
            ],

            const SizedBox(height: 24),

            // Test sentences
            const Text(
              'Test Sentences',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),

            _buildSentenceCard('Query', queryText, Colors.blue, Icons.search),
            const SizedBox(height: 12),
            _buildSentenceCard(
              'Similar (should score HIGH)',
              similarText,
              Colors.green,
              Icons.check_circle,
            ),
            const SizedBox(height: 12),
            _buildSentenceCard(
              'Different (should score LOW)',
              differentText,
              Colors.red,
              Icons.cancel,
            ),

            const SizedBox(height: 24),

            // Generate button
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isGenerating ? null : _generateAndCompare,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isGenerating
                          ? Colors.grey
                          : const Color(0xFF1a4a7c),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    icon: _isGenerating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(Icons.play_arrow),
                    label: Text(
                      _isGenerating
                          ? 'Calculating...'
                          : 'Calculate Similarities',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _clearResults,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[600],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 24,
                    ),
                  ),
                  child: const Text('Clear'),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Results
            if (_errorMessage != null)
              Card(
                color: Colors.red[900],
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.error, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            'Error',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),

            if (_querySimilarSimilarity != null &&
                _queryDifferentSimilarity != null) ...[
              const Text(
                'Similarity Scores',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),

              _buildSimilarityCard(
                'Query vs Similar',
                _querySimilarSimilarity!,
                Colors.green,
                'High similarity indicates these texts are semantically related',
              ),

              const SizedBox(height: 12),

              _buildSimilarityCard(
                'Query vs Different',
                _queryDifferentSimilarity!,
                Colors.red,
                'Low similarity indicates these texts are semantically different',
              ),

              const SizedBox(height: 24),

              // Interpretation
              Card(
                color: const Color(0xFF1a3a5c),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.info, color: Colors.blue),
                          SizedBox(width: 8),
                          Text(
                            'Interpretation',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildInterpretationText(
                        'Cosine similarity ranges from -1 to 1:',
                      ),
                      _buildInterpretationText('  • 1.0 = Identical meaning'),
                      _buildInterpretationText('  • 0.8-1.0 = Very similar'),
                      _buildInterpretationText(
                        '  • 0.5-0.8 = Moderately similar',
                      ),
                      _buildInterpretationText('  • 0.0-0.5 = Weakly similar'),
                      _buildInterpretationText(
                        '  • <0.0 = Opposite meaning (rare)',
                      ),
                      const SizedBox(height: 12),
                      _buildInterpretationText(
                        '🎯 Expected: "Mars" should score higher than "Pluto" because the query asks about the Red Planet, which is Mars.',
                        color: Colors.greenAccent,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgressCard() {
    final percent = _downloadPercent!;
    final showPercent = percent < 100;
    return Card(
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.blue,
                value: showPercent ? percent / 100.0 : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                showPercent
                    ? 'Downloading $_downloadStage… $percent%'
                    : 'Installing model…',
                style: const TextStyle(color: Colors.white60),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSentenceCard(
    String label,
    String text,
    Color color,
    IconData icon,
  ) {
    return Card(
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '"$text"',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimilarityCard(
    String label,
    double score,
    Color color,
    String explanation,
  ) {
    final percentage = (score * 100).toStringAsFixed(1);
    final scoreText = score.toStringAsFixed(4);

    return Card(
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color),
                  ),
                  child: Text(
                    scoreText,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (score + 1) / 2, // Normalize -1 to 1 range to 0 to 1
                minHeight: 24,
                backgroundColor: Colors.white24,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '$percentage%',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              explanation,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInterpretationText(String text, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Text(
        text,
        style: TextStyle(color: color ?? Colors.white70, fontSize: 13),
      ),
    );
  }
}
