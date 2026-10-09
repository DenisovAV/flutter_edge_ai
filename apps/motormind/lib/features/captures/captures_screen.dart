import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../browser/browser_service.dart';
import '../recipes/recipe_store.dart';
import 'capture_service.dart';

/// Captures: the pages a person saved from the web pane, the recipe status
/// per site, and the short list of pages worth capturing next. This is how
/// real pages reach the tests without any automated loading of live sites.
class CapturesScreen extends ConsumerWidget {
  const CapturesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final captures = ref.watch(captureStoreProvider);
    final recipes = ref.watch(recipeStoreProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Captures')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Motormind reads listing sites with a small recipe per site. Sites change; when a '
            'recipe stops working, a captured page is what fixes it. Browse as you normally '
            'would, then tap Capture on the web pane. Nothing is loaded automatically.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Text('Recipes', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          switch (recipes) {
            AsyncData(:final value) => Column(
              children: [
                for (final r in value.values)
                  ListTile(
                    key: Key('recipe-${r.siteId}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(switch (r.status) {
                      'verified' => Icons.check_circle_outline,
                      'broken' => Icons.build_circle_outlined,
                      _ => Icons.help_outline,
                    }),
                    title: Text(
                      '${CuratedSites.byId(r.siteId)?.name ?? r.siteId} · v${r.version} · ${r.status}',
                    ),
                    subtitle: r.note == null ? null : Text(r.note!),
                  ),
              ],
            ),
            AsyncError(:final error) => Text('Could not load recipes: $error'),
            _ => const LinearProgressIndicator(),
          },
          const SizedBox(height: 16),
          Text('Pages worth capturing', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final t in captureTasks)
            Card(
              key: Key('task-${t.id}'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(t.title, style: theme.textTheme.titleSmall)),
                        if (captures.value?.any((c) => c.task == t.id) ?? false)
                          const Icon(Icons.check, size: 18),
                      ],
                    ),
                    for (var i = 0; i < t.steps.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('${i + 1}. ${t.steps[i]}', style: theme.textTheme.bodySmall),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text('Saved', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          switch (captures) {
            AsyncData(:final value) when value.isEmpty => Text(
              'Nothing yet. Open a listings page in the web pane and tap Capture.',
              style: theme.textTheme.bodySmall,
            ),
            AsyncData(:final value) => Column(
              children: [
                for (final c in value)
                  ListTile(
                    key: Key('capture-${c.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      c.title.isEmpty ? c.url : c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        CuratedSites.byId(c.siteId)?.name ?? c.siteId,
                        c.capturedLabel,
                        c.sizeLabel,
                        if (c.check case final check?) check.ok ? 'recipe ok' : 'recipe failed',
                        ?c.task,
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => ref.read(captureStoreProvider.notifier).delete(c),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  kDebugMode
                      ? 'Files are in the app\'s documents folder under captures/. From a computer: '
                            'adb shell run-as com.sirisdevelopment.motormind ls app_flutter/captures'
                      : 'Files are in the app\'s documents folder under captures/.',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            AsyncError(:final error) => Text('Could not list captures: $error'),
            _ => const LinearProgressIndicator(),
          },
        ],
      ),
    );
  }
}

/// The Capture control on the web pane. Saves the page as it is right now,
/// with the recipe's verdict, and lets the person tag it with a task.
class CaptureButton extends ConsumerWidget {
  const CaptureButton({super.key});

  /// Site id used when the page is not on a curated site.
  static const _unknownSite = 'other';

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: const Key('capture-page'),
    tooltip: 'Capture this page for the recipe tests',
    icon: const Icon(Icons.photo_camera_outlined, size: 18),
    visualDensity: VisualDensity.compact,
    onPressed: () => _capture(context, ref),
  );

  Future<void> _capture(BuildContext context, WidgetRef ref) async {
    // The messenger is taken before the first await: the context may be gone
    // by the time the sheet closes.
    final messenger = ScaffoldMessenger.of(context);
    final siteId = BrowserService.siteIdFor(ref.read(browserProvider).url) ?? _unknownSite;
    final task = await _askWhichPage(context, siteId);
    if (task == null) return;
    try {
      final snap = await ref.read(browserProvider.notifier).snapshot();
      SelfCheck? check;
      final recipe = ref.read(recipeStoreProvider.notifier).forSite(siteId);
      if (recipe != null && snap.html.isNotEmpty) {
        check = const RecipeReader()
            .read(snap.html, recipe, sourceUrl: snap.url, now: DateTime.now())
            .check;
      }
      final c = await ref
          .read(captureStoreProvider.notifier)
          .save(
            siteId: siteId,
            url: snap.url,
            title: snap.title,
            html: snap.html,
            check: check,
            task: task.isEmpty ? null : task,
          );
      final verdict = switch (check) {
        null => '',
        SelfCheck(ok: true) => '; the recipe reads it',
        SelfCheck(:final problems) =>
          '; the recipe fails on it (${problems.firstOrNull ?? 'no detail'})',
      };
      messenger.showSnackBar(SnackBar(content: Text('Captured ${c.sizeLabel}$verdict')));
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not capture: $e')));
    }
  }

  /// Asks which task the page answers; returns the task id, an empty string
  /// for "just this page", or null when dismissed.
  Future<String?> _askWhichPage(
    BuildContext context,
    String siteId,
  ) => showModalBottomSheet<String?>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Which page is this?')),
          for (final t in captureTasks.where((t) => t.siteId == siteId || siteId == _unknownSite))
            ListTile(title: Text(t.title), onTap: () => Navigator.pop(context, t.id)),
          ListTile(title: const Text('Just this page'), onTap: () => Navigator.pop(context, '')),
        ],
      ),
    ),
  );
}
