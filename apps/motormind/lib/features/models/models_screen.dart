import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../../services/token_store.dart';
import '../advisor/display_agent.dart';
import 'model_catalog.dart';

/// The model picker (VA-1.2.1) and download manager (VA-1.3.1, VA-1.3.2).
class ModelsScreen extends ConsumerWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(advisorModelServiceProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Models'),
        actions: [
          IconButton(
            key: const Key('models-token'),
            tooltip: 'Hugging Face token',
            icon: const Icon(Icons.key_outlined),
            onPressed: () => _editToken(context, ref),
          ),
        ],
      ),
      body: models.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('The on-device engine could not start.\n\n$e'),
        ),
        data: (state) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                'Models run entirely on this device. Downloads come from the public '
                'litert-community catalog; no account is needed.',
              ),
            ),
            for (final m in ModelCatalog.all) _ModelCard(spec: m, status: state.statusOf(m)),
            const SizedBox(height: 16),
            // DD-R33 / TQ59: one model, two sessions. The second session gets
            // the screen state and returns a few layout decisions; the rules
            // table is its fallback and its benchmark. Off by default until
            // the replay cost is measured on a phone.
            SwitchListTile(
              key: const Key('display-agent-switch'),
              title: const Text('Let a second session arrange the screen'),
              subtitle: const Text(
                'Experimental. The loaded model gets a one-line screen state and decides what '
                'to show; the rules decide otherwise. Each decision costs a short prefill, and '
                'on this engine a session switch replays the conversation.',
              ),
              value: ref.watch(displayAgentModeProvider) == 'model',
              onChanged: (v) =>
                  ref.read(displayAgentModeProvider.notifier).set(v ? 'model' : 'rules'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editToken(BuildContext context, WidgetRef ref) async {
    final store = ref.read(tokenStoreProvider);
    final controller = TextEditingController(text: await store.read() ?? '');
    if (!context.mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hugging Face token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Only needed for gated models or a private mirror. Stored in secure storage on '
              'this device and sent only to the model host.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('token-field'),
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'hf_…'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Clear')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result.isEmpty) {
      await store.clear();
    } else {
      await store.write(result);
    }
  }
}

class _ModelCard extends ConsumerWidget {
  const _ModelCard({required this.spec, required this.status});

  final AdvisorModelSpec spec;
  final ModelStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(advisorModelServiceProvider.notifier);
    final theme = Theme.of(context);
    final isDefault = spec.id == ModelCatalog.defaultModel.id;

    return Card(
      key: Key('model-${spec.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(spec.displayName, style: theme.textTheme.titleMedium)),
                if (isDefault)
                  const Chip(label: Text('Default'), visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 4),
            Text(spec.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              '${spec.sizeLabel} · ${spec.supportsTools ? 'tool calling' : 'chat only'} · '
              '${spec.preferredBackend.name.toUpperCase()}',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 12),
            switch (status) {
              NotInstalled() => FilledButton.icon(
                key: Key('download-${spec.id}'),
                onPressed: () => service.download(spec),
                icon: const Icon(Icons.download),
                label: const Text('Download'),
              ),
              Downloading(:final percent) => Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      key: Key('progress-${spec.id}'),
                      value: percent <= 0 ? null : percent / 100,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('$percent%'),
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: service.cancelDownload,
                  ),
                ],
              ),
              Installed() => Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    key: Key('use-${spec.id}'),
                    onPressed: () => service.activate(spec),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Use this model'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => service.remove(spec),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
                ],
              ),
              Loading() => const Row(
                children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Loading into memory…'),
                ],
              ),
              Ready() => Row(
                children: [
                  Icon(Icons.check_circle, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Active')),
                  OutlinedButton(
                    onPressed: () => service.remove(spec),
                    child: const Text('Remove'),
                  ),
                ],
              ),
              Failed(:final message, :final needsToken) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    needsToken
                        ? 'This host requires a Hugging Face token. Add one with the key icon, then retry.'
                        : message,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => service.download(spec),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }
}
