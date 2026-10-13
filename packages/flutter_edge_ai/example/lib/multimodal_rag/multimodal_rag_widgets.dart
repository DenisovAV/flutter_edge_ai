import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'multimodal_rag_dependencies.dart' show MultimodalRagSetup;
import 'multimodal_rag_audio.dart';
import 'multimodal_rag_item.dart';
import 'multimodal_rag_live.dart';
import 'multimodal_rag_prompt.dart';
import 'multimodal_rag_ranking.dart';
import 'multimodal_rag_theme.dart';
import 'multimodal_rag_view_model.dart';

part 'multimodal_rag_ask_tab.dart';
part 'multimodal_rag_library_tab.dart';
part 'multimodal_rag_live_tab.dart';
part 'multimodal_rag_search_tab.dart';

/// The model lists the screen sends the user to.
enum MultimodalRagModelList { embedder, llm }

typedef OpenModelList = Future<void> Function(MultimodalRagModelList list);

/// Text queries the Search tab suggests. On the sample set each finds its
/// item first (knowledge_retrieval_test.dart): a voice memo, a photo, a memo,
/// a chart, a memo, a note (its chart second), a memo — and a Russian query
/// that finds the English receipt.
const kMultimodalRagSuggestions = [
  'my flight is delayed',
  'the airport taxi receipt',
  'flickering lights',
  'market share chart',
  'fresh basil',
  'revenue by quarter',
  'a cooking class',
  'чек за такси',
];

/// Questions the Ask tab suggests.
const kMultimodalRagQuestions = [
  'How much was the airport taxi?',
  'What is going on with the kitchen?',
  'Who do I have to call on Sunday?',
];

// ── Frame ───────────────────────────────────────────────────────────────────

class MultimodalRagTitle extends StatelessWidget {
  const MultimodalRagTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Multimodal RAG'),
        Text(
          'EmbeddingGemma 2 + Gemma 4',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class MultimodalRagLoading extends StatelessWidget {
  const MultimodalRagLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text('Loading EmbeddingGemma 2…', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Opening the notes, photos and memos indexes',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// No usable embedder (or the indexes did not open): what is wrong, and the
/// way to the model list.
class MultimodalRagSetupProblem extends StatelessWidget {
  const MultimodalRagSetupProblem({
    super.key,
    required this.vm,
    required this.onOpenList,
  });

  final MultimodalRagViewModel vm;
  final OpenModelList onOpenList;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.hub_outlined, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'Multimodal RAG needs EmbeddingGemma 2',
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          vm.error ?? 'The embedding model did not load.',
          key: const Key('multimodal-rag-setup-problem'),
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('multimodal-rag-open-embedder-list'),
          onPressed: () => onOpenList(MultimodalRagModelList.embedder),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Open the Embedding Models list'),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: vm.open, child: const Text('Try again')),
      ],
    );
  }
}

/// A failure, until dismissed.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.vm});

  final MultimodalRagViewModel vm;

  @override
  Widget build(BuildContext context) {
    final error = vm.error;
    if (error == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        key: const Key('multimodal-rag-error'),
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  error,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: vm.clearError,
                icon: Icon(Icons.close, color: scheme.onErrorContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A heading over a section.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.3,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onTertiaryContainer),
                  ),
                ),
              ),
              if (action case final action?)
                TextButton(onPressed: onAction, child: Text(action)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(icon, size: 40, color: theme.colorScheme.outline),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A round tile in a kind's color.
class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind, this.size = 40});

  final MultimodalRagKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = kindColor(kind, Theme.of(context).brightness);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(kindIcon(kind), color: color, size: size * 0.5),
    );
  }
}

/// Plays a memo; a moving waveform while it plays.
class MemoPlayButton extends StatelessWidget {
  const MemoPlayButton({
    super.key,
    required this.vm,
    required this.memo,
    this.size = 40,
  });

  final MultimodalRagViewModel vm;
  final MemoItem memo;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = kindColor(
      MultimodalRagKind.memo,
      Theme.of(context).brightness,
    );
    return ValueListenableBuilder<String?>(
      valueListenable: vm.playing,
      builder: (context, playing, _) {
        final isPlaying = playing == memo.id;
        return Material(
          color: isPlaying ? color : color.withValues(alpha: 0.16),
          shape: const CircleBorder(),
          child: InkWell(
            key: Key('multimodal-rag-play-${memo.id}'),
            customBorder: const CircleBorder(),
            onTap: () => vm.togglePlay(memo),
            child: SizedBox(
              width: size,
              height: size,
              child: isPlaying
                  ? _Waveform(color: Theme.of(context).colorScheme.surface)
                  : Icon(Icons.play_arrow_rounded, color: color),
            ),
          ),
        );
      },
    );
  }
}

class _Waveform extends StatefulWidget {
  const _Waveform({required this.color});

  final Color color;

  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 3,
              height:
                  4 +
                  12 *
                      (0.5 +
                          0.5 *
                              math.sin(
                                (_controller.value + i * 0.23) * 2 * math.pi,
                              )),
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

/// A spoken question: its waveform, never its words. While it is still
/// coming in, the bars fill from the left.
class _VoiceBubble extends StatefulWidget {
  const _VoiceBubble({super.key, required this.run});

  final AnswerRun run;

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: widget.run.spoken == null
        ? Duration.zero
        : pcmDuration(widget.run.spoken!),
    value: widget.run.listening ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.run.listening) unawaited(_fill.forward());
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final levels = widget.run.spokenLevels;
    final spoken = widget.run.spoken;
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.onPrimaryContainer.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.mic, size: 18, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 170,
            height: 34,
            child: AnimatedBuilder(
              animation: _fill,
              builder: (context, _) => CustomPaint(
                painter: _BubbleWavePainter(
                  levels: levels,
                  progress: _fill.value,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            spoken == null ? '' : clock(pcmDuration(spoken)),
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _BubbleWavePainter extends CustomPainter {
  _BubbleWavePainter({
    required this.levels,
    required this.progress,
    required this.color,
  });

  final List<double> levels;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final step = size.width / levels.length;
    final on = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2, step * 0.55);
    final off = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = on.strokeWidth;
    for (final (i, level) in levels.indexed) {
      final h = math.max(3.0, math.min(1.0, level * 1.6) * size.height);
      final x = step * (i + 0.5);
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        (i + 0.5) / levels.length <= progress ? on : off,
      );
    }
  }

  @override
  bool shouldRepaint(_BubbleWavePainter old) =>
      old.progress != progress || old.levels != levels;
}

/// A photo, decoded at the size it is shown.
class MultimodalRagThumb extends StatelessWidget {
  const MultimodalRagThumb({
    super.key,
    required this.image,
    required this.size,
    this.height,
    this.fit = BoxFit.cover,
  });

  final ImageProvider image;
  final double size;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final h = height ?? size;
    final px =
        (math.max(size, h) *
                math.max(2.0, MediaQuery.devicePixelRatioOf(context)))
            .round();
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image(
        image: ResizeImage(
          image,
          width: px,
          height: px,
          policy: ResizeImagePolicy.fit,
        ),
        width: size,
        height: h,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: h,
          color: scheme.surfaceContainerHighest,
          child: Icon(Icons.broken_image_outlined, color: scheme.outline),
        ),
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.keyPrefix,
    required this.suggestions,
    required this.onTap,
  });

  final String keyPrefix;
  final List<String> suggestions;
  final void Function(String text) onTap;

  @override
  Widget build(BuildContext context) {
    // A row, not a lazy list: every chip exists, so one can be scrolled to.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, suggestion) in suggestions.indexed)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
              child: ActionChip(
                key: Key('$keyPrefix-$i'),
                avatar: const Icon(Icons.north_east, size: 16),
                label: Text(suggestion),
                onPressed: () => onTap(suggestion),
              ),
            ),
        ],
      ),
    );
  }
}

/// Fades and slides its child in, after [delay].
class _Appear extends StatefulWidget {
  const _Appear({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<_Appear> createState() => _AppearState();
}

class _AppearState extends State<_Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  Timer? _start;

  @override
  void initState() {
    super.initState();
    _start = Timer(widget.delay, _controller.forward);
  }

  @override
  void dispose() {
    _start?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(curve),
        child: widget.child,
      ),
    );
  }
}

// ── Answers (Ask and Live) ──────────────────────────────────────────────────

/// The retrieved items, numbered as the answer cites them.
class _SourcesStrip extends StatelessWidget {
  const _SourcesStrip({required this.vm, required this.run});

  final MultimodalRagViewModel vm;
  final AnswerRun run;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: run.text,
      builder: (context, answer, _) {
        final cited = citedSources(answer);
        return SizedBox(
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: run.sources.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => _SourceChip(
              vm: vm,
              source: run.sources[i],
              cited: cited.contains(run.sources[i].number),
            ),
          ),
        );
      },
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.vm,
    required this.source,
    required this.cited,
  });

  final MultimodalRagViewModel vm;
  final MultimodalRagSource source;
  final bool cited;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = source.item;
    final color = kindColor(item.kind, theme.brightness);
    final sent = switch (item) {
      PhotoItem() when source.attached => ' · seen',
      MemoItem() when source.attached => ' · heard',
      _ => '',
    };
    return AnimatedContainer(
      key: Key('multimodal-rag-source-${source.number}'),
      duration: const Duration(milliseconds: 300),
      width: 176,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cited
            ? color.withValues(alpha: 0.18)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cited ? color : theme.colorScheme.outlineVariant,
          width: cited ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          switch (item) {
            PhotoItem(:final reference) => MultimodalRagThumb(
              image: vm.imageFor(reference),
              size: 44,
            ),
            MemoItem() => MemoPlayButton(vm: vm, memo: item, size: 44),
            NoteItem() => const _KindBadge(
              kind: MultimodalRagKind.note,
              size: 44,
            ),
          },
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '[${source.number}] ${item.kind.label}$sent',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The streamed answer, its citations drawn as small numbered pills, and
/// under it a card for each source it cites.
class _AnswerCard extends StatelessWidget {
  const _AnswerCard({
    required this.vm,
    required this.run,
    this.cardKey = const Key('multimodal-rag-answer'),
    this.highlighted = false,
  });

  final MultimodalRagViewModel vm;
  final AnswerRun run;
  final Key cardKey;

  /// Live's climax: the answer card stands out.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final llm = vm.setup?.llm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          key: cardKey,
          color: highlighted
              ? Color.alphaBlend(
                  theme.colorScheme.primary.withValues(alpha: 0.10),
                  theme.colorScheme.surfaceContainerHigh,
                )
              : null,
          shape: highlighted
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      llm?.name ?? 'Answer',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: run.text,
                  builder: (context, answer, _) {
                    if (answer.isEmpty && run.busy) {
                      return _Thinking(vm: vm, run: run);
                    }
                    return _CitedText(
                      run: run,
                      text: answer.trim(),
                      streaming: run.busy,
                    );
                  },
                ),
                if (_stats(vm, run) case final stats?) ...[
                  const SizedBox(height: 12),
                  Text(
                    stats,
                    key: const Key('multimodal-rag-answer-stats'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: run.text,
          builder: (context, answer, _) {
            final cited = [
              for (final n in citedSources(answer))
                ?run.sources.where((s) => s.number == n).firstOrNull,
            ];
            if (cited.isEmpty || run.busy) return const SizedBox.shrink();
            return Column(
              children: [
                for (final source in cited)
                  _Appear(
                    key: ValueKey('cite-${run.question}-${source.number}'),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _CitationCard(
                        vm: vm,
                        source: source,
                        compact: highlighted,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  static String? _stats(MultimodalRagViewModel vm, AnswerRun run) {
    final parts = [
      if (run.retrievalTook case final t?) 'retrieved in ${shortDuration(t)}',
      if (run.firstWordsAfter case final t?) 'first words ${shortDuration(t)}',
      if (run.chunksPerSecond case final rate?)
        '${rate.toStringAsFixed(1)} tok/s',
      if (vm.llmBackend case final backend? when vm.llmState == LlmState.ready)
        'on $backend',
      if (run.sentImage) 'photo sent',
      if (run.sentAudio) 'audio sent',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// A cited source, large: the photo the answer was read from, the note, the
/// memo.
class _CitationCard extends StatelessWidget {
  const _CitationCard({
    required this.vm,
    required this.source,
    this.compact = false,
  });

  final MultimodalRagViewModel vm;
  final MultimodalRagSource source;

  /// Smaller, in Live, where the photo already surfaced above.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = source.item;
    final color = kindColor(item.kind, theme.brightness);
    final caption = switch (item) {
      PhotoItem() when source.attached => 'Read from this photo',
      PhotoItem() => 'Photo',
      MemoItem() when source.attached => 'Heard in this memo',
      MemoItem() => 'Voice memo',
      NoteItem() => 'Note',
    };
    return Container(
      key: Key('multimodal-rag-citation-${source.number}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          switch (item) {
            PhotoItem(:final reference) => MultimodalRagThumb(
              image: vm.imageFor(reference),
              size: compact ? 64 : 110,
              height: compact ? 88 : 150,
              fit: BoxFit.contain,
            ),
            MemoItem() => MemoPlayButton(vm: vm, memo: item, size: 56),
            NoteItem() => const _KindBadge(
              kind: MultimodalRagKind.note,
              size: 56,
            ),
          },
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${source.number}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        caption.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(item.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  switch (item) {
                    NoteItem(:final body) => body,
                    PhotoItem() =>
                      'No caption, no OCR: EmbeddingGemma 2 found it by what '
                          'it shows, Gemma 4 read it.',
                    MemoItem(:final duration) =>
                      '${clock(duration)} · found by what is said in it',
                  },
                  maxLines: 4,
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
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking({required this.vm, required this.run});

  final MultimodalRagViewModel vm;
  final AnswerRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (vm.llmState) {
      LlmState.loading => 'Loading ${vm.setup?.llm?.name ?? 'the model'}…',
      _ when run.sentImage => 'Looking at the photo…',
      _ when run.sentAudio => 'Listening…',
      _ => 'Reading the sources…',
    };
    return Row(
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _CitedText extends StatelessWidget {
  const _CitedText({
    required this.run,
    required this.text,
    required this.streaming,
  });

  final AnswerRun run;
  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge?.copyWith(height: 1.45);
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in RegExp(r'\[(\d+(?:\s*,\s*\d+)*)\]').allMatches(text)) {
      if (match.start > last) {
        spans.addAll(_amounts(text.substring(last, match.start)));
      }
      // Punctuation right after a citation stays with it, so a line never
      // starts with the full stop that ends the cited sentence.
      var end = match.end;
      final trailing = end < text.length && '.,;:!?'.contains(text[end])
          ? text[end]
          : '';
      end += trailing.length;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final number in match.group(1)!.split(','))
                _citation(theme, int.tryParse(number.trim())),
              if (trailing.isNotEmpty) Text(trailing, style: base),
            ],
          ),
        ),
      );
      last = end;
    }
    if (last < text.length) spans.addAll(_amounts(text.substring(last)));
    if (streaming) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _Cursor(color: theme.colorScheme.primary),
        ),
      );
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      key: const Key('multimodal-rag-answer-text'),
    );
  }

  /// [text] with its amounts ("26.50", "£40") in bold: what was read off a
  /// receipt stands out.
  static List<InlineSpan> _amounts(String text) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in RegExp(r'[£$€]?\d+[.,]\d{2}\b').allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(
        TextSpan(
          text: m.group(0),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  /// A source number as a small pill in its kind's color.
  Widget _citation(ThemeData theme, int? n) {
    final source = run.sources.where((s) => s.number == n).firstOrNull;
    final color = source == null
        ? theme.colorScheme.outline
        : kindColor(source.item.kind, theme.brightness);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '${n ?? '?'}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Cursor extends StatefulWidget {
  const _Cursor({required this.color});

  final Color color;

  @override
  State<_Cursor> createState() => _CursorState();
}

class _CursorState extends State<_Cursor> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _controller,
    child: Container(
      width: 8,
      height: 16,
      margin: const EdgeInsets.only(left: 2),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

// ── About ───────────────────────────────────────────────────────────────────

Future<void> showMultimodalRagAbout(
  BuildContext context,
  MultimodalRagViewModel vm,
) {
  final embedder = vm.setup?.embedder;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      Widget para(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: theme.textTheme.bodyMedium),
      );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('How it works', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              para(
                'Everything runs on this device. EmbeddingGemma 2'
                '${embedder == null ? '' : ' (${embedder.name})'} turns notes '
                '(their text), photos (their pixels) and voice memos (their '
                'sound) into vectors in ONE space, each kind in its own '
                'SQLite index (flutter_edge_ai_rag, sqlite-vec). Nothing is '
                'transcribed and nothing is captioned.',
              ),
              para(
                'A query — text, a photo, or a few seconds of a meeting — is '
                'compared with all three. Each kind has its own baseline '
                'similarity, so a hit is ranked by how far it stands out from '
                'the rest of its kind; the bar shows that, the number is the '
                'raw cosine.',
              ),
              para(
                'Ask retrieves the closest $kAnswerSources items and sends '
                'them to Gemma 4 as numbered sources — the best photo as an '
                'image and the best memo as a recording — and the answer '
                'cites them.',
              ),
              para(
                'Live cuts the meeting into windows of about five seconds. '
                'EmbeddingGemma 2 files each one by its sound; Gemma 4 hears '
                'it and names any question asked, which is then answered '
                'from your library.',
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A window's place in the meeting: "0:13–0:18".
String windowSpan(MeetingWindow w) => '${clock(w.start)}–${clock(w.end)}';
