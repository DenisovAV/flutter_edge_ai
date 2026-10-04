import 'package:flutter/material.dart';

import '../secret_store.dart';
import '../skill.dart';
import '../skill_registry.dart';
import 'add_skill_disclaimer.dart';
import 'secret_editor_dialog.dart';

/// A featured skill the user can add from a curated list (Gallery's
/// "featured skills"). The [add] callback fetches + parses the skill (the host
/// owns the network / asset access) and returns the [Skill] to register.
class FeaturedSkill {
  const FeaturedSkill({
    required this.name,
    required this.description,
    required this.add,
  });

  /// Display name (kebab-case skill id, e.g. `calculate-hash`).
  final String name;

  /// One-line description shown in the featured list.
  final String description;

  /// Fetch + parse the skill. Throws on failure (surfaced to the user).
  final Future<Skill> Function() add;
}

/// Lists the registry's skills with on/off toggles and entry points to add a
/// skill from URL, import one, or pick from a featured list.
///
/// Adaptive: mount it inside [SkillManagerView.showAdaptive] to get a bottom
/// sheet on a narrow window and a side-panel dialog on a wide one (mirrors
/// Gallery's `SkillManagerBottomSheet`, made desktop-friendly). The add actions
/// are callbacks so the host owns network / file access (the package stays UI +
/// registry only); each is wired only if provided.
class SkillManagerView extends StatefulWidget {
  const SkillManagerView({
    super.key,
    required this.registry,
    this.secretStore,
    this.onAddFromUrl,
    this.onImport,
    this.featured = const [],
    this.onChanged,
  });

  /// The catalog to display and toggle.
  final SkillRegistry registry;

  /// Where `require-secret` skills' keys are stored. When non-null, such skills
  /// show a "key" action that opens the [SecretEditorDialog].
  final SecretStore? secretStore;

  /// Fetch + parse a skill from a user-entered URL. Null hides the URL action.
  final Future<Skill> Function(String url)? onAddFromUrl;

  /// Import a skill (e.g. a local folder / file picked by the host). Returns the
  /// parsed [Skill], or null if the user cancelled. Null hides the import action.
  final Future<Skill?> Function()? onImport;

  /// Curated skills offered in the "Featured" picker. Empty hides it.
  final List<FeaturedSkill> featured;

  /// Called whenever the catalog or a selection changes, so the host can persist.
  final VoidCallback? onChanged;

  /// Show the manager adaptively: a modal bottom sheet on a narrow window
  /// (< 600 dp), a right-hand side panel dialog on a wide one.
  static Future<void> showAdaptive(
    BuildContext context, {
    required SkillRegistry registry,
    SecretStore? secretStore,
    Future<Skill> Function(String url)? onAddFromUrl,
    Future<Skill?> Function()? onImport,
    List<FeaturedSkill> featured = const [],
    VoidCallback? onChanged,
  }) {
    final view = SkillManagerView(
      registry: registry,
      secretStore: secretStore,
      onAddFromUrl: onAddFromUrl,
      onImport: onImport,
      featured: featured,
      onChanged: onChanged,
    );
    final wide = MediaQuery.of(context).size.width >= 600;
    if (wide) {
      return showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          alignment: Alignment.centerRight,
          insetPadding: const EdgeInsets.all(16),
          child: SizedBox(
            width: 420,
            height: double.infinity,
            child: _Panel(title: 'Skills', child: view),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: _Panel(title: 'Skills', child: view),
      ),
    );
  }

  @override
  State<SkillManagerView> createState() => _SkillManagerViewState();
}

class _SkillManagerViewState extends State<SkillManagerView> {
  void _notify() {
    setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _addFromUrl() async {
    final agreed = await AddSkillDisclaimerDialog.show(context);
    if (!agreed || !mounted) return;
    final url = await _promptForUrl();
    if (url == null || url.isEmpty || !mounted) return;
    await _runAdd(() => widget.onAddFromUrl!(url));
  }

  Future<void> _import() async {
    final agreed = await AddSkillDisclaimerDialog.show(context);
    if (!agreed || !mounted) return;
    await _runAdd(() async => widget.onImport!());
  }

  Future<void> _addFeatured(FeaturedSkill featured) async {
    final agreed = await AddSkillDisclaimerDialog.show(context);
    if (!agreed || !mounted) return;
    await _runAdd(featured.add);
  }

  /// Run [add], register the result (selected), and surface any error.
  Future<void> _runAdd(Future<Skill?> Function() add) async {
    try {
      final skill = await add();
      if (skill == null || !mounted) return;
      widget.registry.add(skill, selected: true);
      _notify();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add skill: $e')));
      }
    }
  }

  Future<String?> _promptForUrl() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add skill from URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…/SKILL.md',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFeatured() async {
    final picked = await showModalBottomSheet<FeaturedSkill>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          for (final f in widget.featured)
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: Text(f.name),
              subtitle: Text(f.description),
              onTap: () => Navigator.of(context).pop(f),
            ),
        ],
      ),
    );
    if (picked != null) await _addFeatured(picked);
  }

  @override
  Widget build(BuildContext context) {
    final skills = widget.registry.all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AddBar(
          onAddFromUrl: widget.onAddFromUrl != null ? _addFromUrl : null,
          onImport: widget.onImport != null ? _import : null,
          onFeatured: widget.featured.isNotEmpty ? _pickFeatured : null,
        ),
        const Divider(height: 1),
        Expanded(
          child: skills.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No skills yet. Add one from a URL, import a folder, '
                      'or pick a featured skill.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: skills.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _SkillTile(
                    skill: skills[i],
                    selected: widget.registry.isSelected(skills[i].name),
                    hasSecret: widget.secretStore?.has(skills[i].name) ?? false,
                    onToggle: (on) {
                      if (on) {
                        widget.registry.select(skills[i].name);
                      } else {
                        widget.registry.unselect(skills[i].name);
                      }
                      _notify();
                    },
                    onRemove: () {
                      widget.registry.remove(skills[i].name);
                      widget.secretStore?.remove(skills[i].name);
                      _notify();
                    },
                    onEditSecret: widget.secretStore == null
                        ? null
                        : () async {
                            await SecretEditorDialog.show(
                              context,
                              skill: skills[i],
                              store: widget.secretStore!,
                            );
                            if (mounted) _notify();
                          },
                  ),
                ),
        ),
      ],
    );
  }
}

class _AddBar extends StatelessWidget {
  const _AddBar({this.onAddFromUrl, this.onImport, this.onFeatured});

  final VoidCallback? onAddFromUrl;
  final VoidCallback? onImport;
  final VoidCallback? onFeatured;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (onAddFromUrl != null)
            OutlinedButton.icon(
              onPressed: onAddFromUrl,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('From URL'),
            ),
          if (onImport != null)
            OutlinedButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Import'),
            ),
          if (onFeatured != null)
            OutlinedButton.icon(
              onPressed: onFeatured,
              icon: const Icon(Icons.star_outline, size: 18),
              label: const Text('Featured'),
            ),
        ],
      ),
    );
  }
}

class _SkillTile extends StatelessWidget {
  const _SkillTile({
    required this.skill,
    required this.selected,
    required this.hasSecret,
    required this.onToggle,
    required this.onRemove,
    this.onEditSecret,
  });

  final Skill skill;
  final bool selected;
  final bool hasSecret;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;
  final VoidCallback? onEditSecret;

  IconData get _typeIcon => switch (skill.type) {
    SkillType.js => Icons.javascript,
    SkillType.intent => Icons.bolt_outlined,
    SkillType.mcp => Icons.cloud_outlined,
    SkillType.textOnly => Icons.notes_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(_typeIcon),
      title: Row(
        children: [
          Flexible(child: Text(skill.name, overflow: TextOverflow.ellipsis)),
          if (skill.requireSecret) ...[
            const SizedBox(width: 6),
            Icon(
              hasSecret ? Icons.key : Icons.key_off,
              size: 14,
              color: hasSecret
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
          ],
        ],
      ),
      subtitle: Text(
        skill.description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: selected, onChanged: onToggle),
          PopupMenuButton<String>(
            tooltip: 'Skill actions',
            onSelected: (value) {
              switch (value) {
                case 'secret':
                  onEditSecret?.call();
                case 'remove':
                  onRemove();
              }
            },
            itemBuilder: (context) => [
              if (skill.requireSecret && onEditSecret != null)
                PopupMenuItem(
                  value: 'secret',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.key),
                    title: Text(hasSecret ? 'Edit secret' : 'Add secret'),
                  ),
                ),
              const PopupMenuItem(
                value: 'remove',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline),
                  title: Text('Remove skill'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A titled container used by the adaptive sheet / side panel.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
