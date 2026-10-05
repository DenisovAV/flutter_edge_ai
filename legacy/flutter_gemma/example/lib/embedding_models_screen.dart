import 'package:flutter/material.dart';
import 'package:flutter_gemma_example/models/embedding_model.dart';
import 'package:flutter_gemma_example/widgets/universal_model_card.dart';

class EmbeddingModelsScreen extends StatefulWidget {
  const EmbeddingModelsScreen({super.key});

  @override
  State<EmbeddingModelsScreen> createState() => _EmbeddingModelsScreenState();
}

class _EmbeddingModelsScreenState extends State<EmbeddingModelsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Embedding Models'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              'RAG Embedding Models',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Download and manage embedding models for Retrieval-Augmented Generation',
              style: TextStyle(fontSize: 16, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Expanded(
              child: ListView.builder(
                itemCount: EmbeddingModel.values.length,
                itemBuilder: (context, index) {
                  final model = EmbeddingModel.values[index];
                  return UniversalModelCard(model: model);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
