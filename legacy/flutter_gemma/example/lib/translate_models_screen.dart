import 'package:flutter/material.dart';
import 'package:flutter_gemma_example/models/translate_model.dart';
import 'package:flutter_gemma_example/widgets/universal_model_card.dart';

class TranslateModelsScreen extends StatefulWidget {
  const TranslateModelsScreen({super.key});

  @override
  State<TranslateModelsScreen> createState() => _TranslateModelsScreenState();
}

class _TranslateModelsScreenState extends State<TranslateModelsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Translation Models'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              'On-device Translation',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'TranslateGemma 4B — single-shot translation across 55 languages. '
              'Community-converted .litertlm (Google has not yet released a '
              'mobile/desktop bundle).',
              style: TextStyle(fontSize: 14, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView.builder(
                itemCount: TranslateModel.values.length,
                itemBuilder: (context, index) {
                  final model = TranslateModel.values[index];
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
