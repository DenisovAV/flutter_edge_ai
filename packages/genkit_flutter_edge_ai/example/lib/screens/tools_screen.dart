import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets/status_banner.dart';

class ToolsScreen extends StatefulWidget {
  final AppState appState;
  final VoidCallback onGoToSettings;

  const ToolsScreen({
    super.key,
    required this.appState,
    required this.onGoToSettings,
  });

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final _promptController = TextEditingController(
    text: 'What is the weather in Paris?',
  );

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final state = widget.appState;

        return Column(
          children: [
            if (!state.inferenceInstalled)
              StatusBanner(
                message: 'Inference model not installed.',
                onAction: widget.onGoToSettings,
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Available Tools',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('get_weather',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontFamily: 'monospace')),
                          const Text('Get current weather for a city'),
                          const Divider(),
                          Text('calculate',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontFamily: 'monospace')),
                          const Text('Calculate a mathematical expression'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: const Text('Agent mode'),
                    subtitle: const Text(
                      'Auto-execute tools and return final answer',
                    ),
                    value: state.agentMode,
                    onChanged: state.isToolGenerating
                        ? null
                        : (v) => state.agentMode = v,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _promptController,
                    decoration: const InputDecoration(
                      labelText: 'Prompt',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: state.inferenceInstalled && !state.isToolGenerating
                        ? () => state.generateWithTools(_promptController.text)
                        : null,
                    child: state.isToolGenerating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Generate with Tools'),
                  ),
                  const SizedBox(height: 24),
                  if (state.lastToolResult != null) ...[
                    Text('Result:',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          state.lastToolResult!,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
