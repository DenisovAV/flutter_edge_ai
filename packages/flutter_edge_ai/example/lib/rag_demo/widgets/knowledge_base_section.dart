import 'package:flutter/material.dart';
import '../rag_demo_data.dart';
import 'sample_documents_screen.dart';

class KnowledgeBaseSection extends StatelessWidget {
  final bool isLoading;
  final int addTimeMs;
  final VoidCallback onAddDocuments;
  final VoidCallback onClearDocuments;

  const KnowledgeBaseSection({
    super.key,
    required this.isLoading,
    required this.addTimeMs,
    required this.onAddDocuments,
    required this.onClearDocuments,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Knowledge Base',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),

        // Buttons
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: isLoading
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (context) => SampleDocumentsScreen(
                              onAddDocuments: onAddDocuments,
                              isLoading: isLoading,
                            ),
                          ),
                        );
                      },
                icon: const Icon(Icons.add),
                label: Text('Add ${sampleDocuments.length} Docs'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: isLoading ? null : onClearDocuments,
                icon: const Icon(Icons.delete),
                label: const Text('Clear All'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade900,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
        if (addTimeMs > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Last add: ${addTimeMs}ms',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
      ],
    );
  }
}
