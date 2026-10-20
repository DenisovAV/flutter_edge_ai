part of 'multimodal_rag_widgets.dart';

// ── Library ─────────────────────────────────────────────────────────────────

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key, required this.vm, required this.onOpenList});

  final MultimodalRagViewModel vm;
  final OpenModelList onOpenList;

  @override
  Widget build(BuildContext context) {
    final setup = vm.setup!;
    final recording = vm.recording || vm.keepingMemo;
    // The recording banner floats over the list: Record is far down it.
    return Stack(
      children: [
        _libraryList(setup, bottomPadding: recording ? 96 : 24),
        if (recording)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _RecordingBanner(vm: vm),
          ),
      ],
    );
  }

  Widget _libraryList(
    MultimodalRagSetup setup, {
    required double bottomPadding,
  }) {
    return ListView(
      key: const Key('multimodal-rag-library'),
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPadding),
      children: [
        _ErrorBanner(vm: vm),
        _ModelsCard(vm: vm, onOpenList: onOpenList),
        const SizedBox(height: 12),
        _IndexCard(vm: vm),
        for (final kind in MultimodalRagKind.values)
          if (kind != MultimodalRagKind.memo || setup.audioSupported) ...[
            _SectionHeader(
              '${kind.plural.toUpperCase()} · ${vm.itemsOf(kind).length}',
              trailing: _AddButton(vm: vm, kind: kind),
            ),
            if (!vm.indexes(kind))
              _Notice(
                icon: Icons.info_outline,
                text: switch (kind) {
                  MultimodalRagKind.photo =>
                    'Photos need EmbeddingGemma 2 with a vision encoder (440M '
                        'or 740M).',
                  _ =>
                    'Voice memos need EmbeddingGemma 2 Text + Vision + Audio '
                        '(740M).',
                },
                action: 'Choose',
                onAction: () => onOpenList(MultimodalRagModelList.embedder),
              ),
            switch (kind) {
              MultimodalRagKind.note => Column(
                children: [
                  for (final note in vm.itemsOf(kind).cast<NoteItem>())
                    _NoteTile(vm: vm, note: note),
                ],
              ),
              MultimodalRagKind.photo => _PhotoGrid(
                vm: vm,
                photos: vm.itemsOf(kind).cast<PhotoItem>(),
              ),
              MultimodalRagKind.memo => Column(
                children: [
                  for (final memo in vm.itemsOf(kind).cast<MemoItem>())
                    _MemoTile(vm: vm, memo: memo),
                ],
              ),
            },
          ],
      ],
    );
  }
}

/// The two models, what they run on, and the way to each model list.
class _ModelsCard extends StatelessWidget {
  const _ModelsCard({required this.vm, required this.onOpenList});

  final MultimodalRagViewModel vm;
  final OpenModelList onOpenList;

  @override
  Widget build(BuildContext context) {
    final setup = vm.setup!;
    final embedder = setup.embedder!;
    final llm = setup.llm;
    return Card(
      key: const Key('multimodal-rag-models'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            _ModelRow(
              icon: Icons.hub_outlined,
              role: 'Embeddings',
              name: embedder.name,
              detail: [
                embedder.backend?.name ?? (kIsWeb ? 'webgpu' : 'cpu'),
                if (vm.openTook case final took?)
                  'opened in ${shortDuration(took)}',
              ].join(' · '),
              onTap: () => onOpenList(MultimodalRagModelList.embedder),
            ),
            _ModelRow(
              icon: Icons.auto_awesome_outlined,
              role: 'Answers',
              name: llm?.name,
              missing: 'Install Gemma 4 E2B',
              detail: switch (vm.llmState) {
                LlmState.loading => 'loading…',
                LlmState.ready =>
                  '${vm.llmBackend} · loaded in ${shortDuration(vm.llmLoadTook!)}',
                LlmState.failed => 'failed to load',
                LlmState.idle => 'loads when needed',
                LlmState.missing => null,
              },
              busy: vm.llmState == LlmState.loading,
              onTap: () => onOpenList(MultimodalRagModelList.llm),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.icon,
    required this.role,
    required this.name,
    required this.onTap,
    this.detail,
    this.missing,
    this.busy = false,
  });

  final IconData icon;
  final String role;
  final String? name;
  final String? detail;
  final String? missing;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final present = name != null;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      onTap: onTap,
      leading: Icon(icon, color: present ? scheme.primary : scheme.error),
      title: Text(
        present ? name! : missing!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: present ? null : scheme.error,
        ),
      ),
      subtitle: Text(
        [role, ?detail].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              present ? Icons.check_circle : Icons.chevron_right,
              size: 18,
              color: present ? scheme.primary : scheme.error,
            ),
    );
  }
}

/// How much is indexed, the run in progress, and the two index commands.
class _IndexCard extends StatelessWidget {
  const _IndexCard({required this.vm});

  final MultimodalRagViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final indexable = [
      for (final item in vm.items)
        if (vm.indexes(item.kind)) item,
    ];
    final done = vm.indexedCount;
    final total = indexable.length;
    final current = vm.indexingId == null
        ? null
        : vm.items.where((i) => i.id == vm.indexingId).firstOrNull;
    return Card(
      key: const Key('multimodal-rag-index-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$done of $total indexed',
                    key: const Key('multimodal-rag-indexed-count'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (done > 0 && !vm.busy)
                  TextButton(
                    key: const Key('multimodal-rag-clear'),
                    onPressed: vm.clearIndex,
                    child: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: total == 0 ? 0 : done / total),
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                builder: (context, value, _) =>
                    LinearProgressIndicator(value: value, minHeight: 8),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              vm.indexing
                  ? 'Embedding ${current?.kind.label.toLowerCase() ?? 'item'}'
                        '${current == null ? '' : ' “${current.title}”'}…'
                  : vm.lastRunTook != null
                  ? 'Last run took ${shortDuration(vm.lastRunTook!)} on the '
                        'device. Every item: one EmbeddingGemma 2 vector.'
                  : 'Notes as text, photos as pixels, memos as sound — one '
                        'embedding space.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (vm.pending.isNotEmpty && !vm.indexing) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('multimodal-rag-index'),
                  onPressed: vm.busy ? null : vm.indexLibrary,
                  icon: const Icon(Icons.bolt),
                  label: Text(
                    'Index ${vm.pending.length} '
                    'item${vm.pending.length == 1 ? '' : 's'}',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The "+" of a section: a note, a photo, or a recorded memo.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.vm, required this.kind});

  final MultimodalRagViewModel vm;
  final MultimodalRagKind kind;

  @override
  Widget build(BuildContext context) {
    final enabled = !vm.busy && vm.indexes(kind);
    return switch (kind) {
      MultimodalRagKind.note => TextButton.icon(
        key: const Key('multimodal-rag-add-note'),
        onPressed: enabled ? () => _addNote(context) : null,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Note'),
      ),
      MultimodalRagKind.photo => TextButton.icon(
        key: const Key('multimodal-rag-add-photo'),
        onPressed: enabled ? vm.addPhoto : null,
        icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
        label: const Text('Photo'),
      ),
      MultimodalRagKind.memo => TextButton.icon(
        key: const Key('multimodal-rag-record'),
        onPressed: enabled ? vm.startRecording : null,
        icon: const Icon(Icons.fiber_manual_record, size: 18),
        label: const Text('Record'),
      ),
    };
  }

  Future<void> _addNote(BuildContext context) async {
    final note = await showModalBottomSheet<({String title, String body})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _NoteSheet(),
    );
    if (note != null && note.body.trim().isNotEmpty) {
      await vm.addNote(title: note.title, body: note.body);
    }
  }
}

/// A new note: a title and its text. Pops the two, or nothing.
class _NoteSheet extends StatefulWidget {
  const _NoteSheet();

  @override
  State<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<_NoteSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New note', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('multimodal-rag-note-title'),
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('multimodal-rag-note-body'),
            controller: _body,
            decoration: const InputDecoration(
              labelText: 'Note (markdown)',
              alignLabelWithHint: true,
            ),
            minLines: 3,
            maxLines: 8,
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('multimodal-rag-note-save'),
            onPressed: () =>
                Navigator.pop(context, (title: _title.text, body: _body.text)),
            child: const Text('Save and index'),
          ),
        ],
      ),
    );
  }
}

class _ItemStatus extends StatelessWidget {
  const _ItemStatus({required this.vm, required this.item});

  final MultimodalRagViewModel vm;
  final MultimodalRagItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final Widget child;
    if (vm.indexingId == item.id) {
      child = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (vm.costOf(item.id) case final cost?) {
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(shortDuration(cost), style: muted),
        ],
      );
    } else if (vm.failureOf(item.id) case final failure?) {
      child = Tooltip(
        message: failure,
        child: Icon(
          Icons.error_outline,
          size: 16,
          color: theme.colorScheme.error,
        ),
      );
    } else if (vm.isQueued(item.id)) {
      child = Icon(Icons.schedule, size: 14, color: muted?.color);
    } else {
      child = Text(vm.indexes(item.kind) ? 'not indexed' : '—', style: muted);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: KeyedSubtree(
        key: ValueKey('${item.id}-${child.runtimeType}-${vm.costOf(item.id)}'),
        child: child,
      ),
    );
  }
}

/// A round tile in a kind's color.
class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.vm, required this.note});

  final MultimodalRagViewModel vm;
  final NoteItem note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        key: Key('multimodal-rag-item-${note.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _KindBadge(kind: MultimodalRagKind.note, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            note.title,
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _ItemStatus(vm: vm, item: note),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      note.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({required this.vm, required this.photos});

  final MultimodalRagViewModel vm;
  final List<PhotoItem> photos;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(3, (constraints.maxWidth / 140).floor());
        const gap = 8.0;
        final size = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final photo in photos)
              SizedBox(
                key: Key('multimodal-rag-item-${photo.id}'),
                width: size,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      children: [
                        MultimodalRagThumb(
                          image: vm.imageFor(photo.reference),
                          size: size,
                        ),
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: _ItemStatus(vm: vm, item: photo),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      photo.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MemoTile extends StatelessWidget {
  const _MemoTile({required this.vm, required this.memo});

  final MultimodalRagViewModel vm;
  final MemoItem memo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        key: Key('multimodal-rag-item-${memo.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              MemoPlayButton(vm: vm, memo: memo),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${memo.title} · ${clock(memo.duration)}',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        _ItemStatus(vm: vm, item: memo),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Found by its sound — no transcript',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Recording (with its clock and Stop), then keeping the memo.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.vm});

  final MultimodalRagViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final since = vm.recordingSince;
    return Material(
      key: const Key('multimodal-rag-recording'),
      color: scheme.errorContainer,
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              vm.recording ? Icons.fiber_manual_record : Icons.hearing,
              color: scheme.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: since == null
                  ? Text(
                      'Keeping the memo…',
                      style: TextStyle(color: scheme.onErrorContainer),
                    )
                  : StreamBuilder<int>(
                      stream: Stream.periodic(
                        const Duration(milliseconds: 250),
                        (i) => i,
                      ),
                      builder: (context, _) => Text(
                        'Recording ${clock(DateTime.now().difference(since))}'
                        ' / ${clock(kMaxMemo)}',
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
            ),
            if (vm.recording)
              FilledButton(
                key: const Key('multimodal-rag-stop-recording'),
                onPressed: vm.stopRecording,
                child: const Text('Stop'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Plays a memo; a moving waveform while it plays.
