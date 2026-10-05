import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

class StatusCard extends StatelessWidget {
  final bool hasEmbeddingModel;
  final String statusMessage;
  final VectorStoreStats? stats;

  const StatusCard({
    super.key,
    required this.hasEmbeddingModel,
    required this.statusMessage,
    this.stats,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(
              hasEmbeddingModel ? Icons.check_circle : Icons.warning,
              color: hasEmbeddingModel ? Colors.green : Colors.orange,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: hasEmbeddingModel ? Colors.green : Colors.orange,
              ),
            ),
            if (stats != null) ...[
              const SizedBox(height: 8),
              Text(
                'Documents: ${stats!.documentCount} | Dimension: ${stats!.vectorDimension}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
