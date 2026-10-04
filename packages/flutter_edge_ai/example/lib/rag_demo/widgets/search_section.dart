import 'package:flutter/material.dart';

class SearchSection extends StatelessWidget {
  final TextEditingController controller;
  final double threshold;
  final int topK;
  final bool isLoading;
  final int searchTimeMs;
  final VoidCallback onSearch;
  final ValueChanged<double> onThresholdChanged;
  final ValueChanged<int> onTopKChanged;

  const SearchSection({
    super.key,
    required this.controller,
    required this.threshold,
    required this.topK,
    required this.isLoading,
    required this.searchTimeMs,
    required this.onSearch,
    required this.onThresholdChanged,
    required this.onTopKChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Search',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: 'Search Query',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: isLoading ? null : onSearch,
            ),
          ),
          onSubmitted: (_) => onSearch(),
        ),
        const SizedBox(height: 16),

        // Sliders
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Threshold: ${threshold.toStringAsFixed(2)}'),
                  Slider(
                    value: threshold,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    onChanged: onThresholdChanged,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Top K: $topK'),
                  Slider(
                    value: topK.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    onChanged: (value) => onTopKChanged(value.round()),
                  ),
                ],
              ),
            ),
          ],
        ),

        ElevatedButton.icon(
          onPressed: isLoading ? null : onSearch,
          icon: isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search),
          label: const Text('Search'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
        if (searchTimeMs > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Search time: ${searchTimeMs}ms',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
      ],
    );
  }
}
