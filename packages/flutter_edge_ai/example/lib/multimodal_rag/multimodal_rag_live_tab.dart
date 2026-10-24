part of 'multimodal_rag_widgets.dart';

/// Live: a meeting, heard as it happens. Its sound is the query — each few
/// seconds EmbeddingGemma 2 embeds them and what they are about surfaces from
/// the library — and when someone asks a question, Gemma 4 hears it and the
/// answer comes from the library too. No cloud, no transcript.
class LiveTab extends StatefulWidget {
  const LiveTab({super.key, required this.vm});

  final MultimodalRagViewModel vm;

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  final _scroll = ScrollController();
  final _cards = <String, GlobalKey>{};
  final _answerKey = GlobalKey();

  MultimodalRagViewModel get vm => widget.vm;

  @override
  void initState() {
    super.initState();
    vm.liveEvents.addListener(_onEvent);
  }

  @override
  void dispose() {
    vm.liveEvents.removeListener(_onEvent);
    _scroll.dispose();
    super.dispose();
  }

  /// One key per card: an item that surfaces again later is a second card.
  GlobalKey _keyFor(SurfacedItem s) =>
      _cards.putIfAbsent('${s.item.id}@${s.window}', GlobalKey.new);

  /// A card surfaced or the question came: follow it.
  void _onEvent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  /// Scrolls to what was surfaced nearest [at], and makes it glow (or
  /// scrolls to the answer).
  void _jumpTo(Duration at, {bool question = false}) {
    final nearest = question || vm.surfaced.isEmpty
        ? null
        : (vm.surfaced.toList()..sort(
                (a, b) =>
                    (a.heardAt - at).abs().compareTo((b.heardAt - at).abs()),
              ))
              .first;
    if (nearest != null) vm.pulse(nearest);
    final target = question
        ? _answerKey
        : nearest == null
        ? null
        : _keyFor(nearest);
    final context = target?.currentContext;
    if (context == null) return;
    unawaited(
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      ),
    );
  }

  Future<void> _searchMeeting() async {
    final query = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _MeetingSearchSheet(),
    );
    if (query == null || query.trim().isEmpty || !mounted) return;
    await vm.searchMeeting(query);
    if (!mounted) return;
    final hit = vm.meetingHit;
    if (hit != null && hit < vm.windows.length) {
      _jumpTo(vm.windows[hit].start);
    }
  }

  @override
  Widget build(BuildContext context) {
    final run = vm.liveRun;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: run,
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: ListView(
              key: const Key('multimodal-rag-live'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                _ErrorBanner(vm: vm),
                _LiveHeader(vm: vm),
                const SizedBox(height: 10),
                _ListeningStrip(vm: vm),
                if (vm.surfaced.isEmpty && vm.liveState == LiveState.idle)
                  const Padding(
                    padding: EdgeInsets.only(top: 28),
                    child: _EmptyHint(
                      icon: Icons.graphic_eq,
                      text:
                          'Start the sample meeting. What it is about surfaces '
                          'from your library as it is said, matched by sound.',
                    ),
                  ),
                for (final s in vm.surfaced)
                  _Appear(
                    key: ValueKey('surfaced-${s.item.id}-${s.window}'),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _SurfacedCard(
                        key: _keyFor(s),
                        vm: vm,
                        surfaced: s,
                      ),
                    ),
                  ),
                if (run.question case final question?) ...[
                  const SizedBox(height: 18),
                  _QuestionQuote(
                    key: _answerKey,
                    question: question,
                    heardAt: run.heardAt,
                    spoken: run.spoken != null,
                  ),
                  const SizedBox(height: 10),
                  _AnswerCard(
                    vm: vm,
                    run: run,
                    cardKey: const Key('multimodal-rag-live-answer'),
                    highlighted: true,
                  ),
                ],
                if (_footer(vm) case final footer?)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      footer,
                      key: const Key('multimodal-rag-live-timings'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (vm.liveState != LiveState.idle)
            _MeetingTimeline(
              vm: vm,
              onSurfaced: (s) => _jumpTo(s.heardAt),
              onQuestion: () => _jumpTo(Duration.zero, question: true),
              onSearch: _searchMeeting,
            ),
        ],
      ),
    );
  }

  static String? _footer(MultimodalRagViewModel vm) {
    final parts = [
      if (vm.windowEmbedding case final t?)
        'EmbeddingGemma 2 ${shortDuration(t)}',
      if (vm.windowHearing case final t?) 'Gemma 4 ${shortDuration(t)}',
    ];
    return parts.isEmpty ? null : '${parts.join(' · ')} per window';
  }
}

/// "Live" + "On device · no cloud", the source, the start and stop button,
/// and the overflow menu.
class _LiveHeader extends StatelessWidget {
  const _LiveHeader({required this.vm});

  final MultimodalRagViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listening = vm.liveState == LiveState.listening;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Wraps under the title at large text sizes.
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Live', style: theme.textTheme.headlineSmall),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'On device · no cloud',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final source in const ['Sample meeting', 'Microphone'])
                    ChoiceChip(
                      key: Key('multimodal-rag-live-source-$source'),
                      label: Text(source),
                      visualDensity: VisualDensity.compact,
                      selected: vm.liveSource == source,
                      onSelected: listening
                          ? null
                          : (_) => vm.chooseLiveSource(source),
                    ),
                ],
              ),
            ],
          ),
        ),
        PopupMenuButton<void>(
          key: const Key('multimodal-rag-live-menu'),
          tooltip: 'More',
          itemBuilder: (context) => [
            PopupMenuItem<void>(
              key: const Key('multimodal-rag-live-just-said'),
              enabled: vm.windows.isNotEmpty && !vm.liveRun.busy,
              onTap: vm.answerWhatWasJustSaid,
              child: const Text('Answer what was just said'),
            ),
          ],
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 56,
          height: 56,
          child: listening
              ? IconButton.filledTonal(
                  key: const Key('multimodal-rag-live-stop'),
                  tooltip: 'Stop listening',
                  onPressed: vm.stopLive,
                  icon: const Icon(Icons.stop_rounded, size: 28),
                )
              : IconButton.filled(
                  key: const Key('multimodal-rag-live-start'),
                  tooltip: 'Start listening',
                  onPressed: vm.startLive,
                  icon: const Icon(Icons.hearing, size: 28),
                ),
        ),
      ],
    );
  }
}

/// The audio as it is heard: a moving waveform and the elapsed time.
class _ListeningStrip extends StatelessWidget {
  const _ListeningStrip({required this.vm});

  final MultimodalRagViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = kindColor(MultimodalRagKind.memo, theme.brightness);
    final status = switch (vm.liveState) {
      LiveState.idle => 'Not listening',
      LiveState.listening => 'Listening to the ${vm.liveSource.toLowerCase()}',
      LiveState.finished => 'Heard the ${vm.liveSource.toLowerCase()}',
    };
    return Container(
      key: const Key('multimodal-rag-live-strip'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 44,
              child: ValueListenableBuilder<List<double>>(
                valueListenable: vm.levels,
                builder: (context, levels, _) => CustomPaint(
                  painter: _LevelsPainter(
                    levels: levels,
                    color: vm.liveState == LiveState.listening
                        ? color
                        : scheme.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Flexible(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  clock(vm.heard),
                  key: const Key('multimodal-rag-live-title'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
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

/// Bars of recent audio levels, newest on the right.
class _LevelsPainter extends CustomPainter {
  _LevelsPainter({required this.levels, required this.color});

  final List<double> levels;
  final Color color;

  static const _bars = 48;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2, size.width / _bars * 0.55);
    final step = size.width / _bars;
    final shown = levels.length > _bars
        ? levels.sublist(levels.length - _bars)
        : levels;
    final offset = _bars - shown.length;
    for (var i = 0; i < _bars; i++) {
      final level = i < offset ? 0.0 : shown[i - offset];
      final h = math.max(3.0, level * size.height);
      final x = step * (i + 0.5);
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LevelsPainter old) =>
      old.levels != levels || old.color != color;
}

/// A library item the meeting surfaced: large, with when it was heard.
class _SurfacedCard extends StatelessWidget {
  const _SurfacedCard({super.key, required this.vm, required this.surfaced});

  final MultimodalRagViewModel vm;
  final SurfacedItem surfaced;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = surfaced.item;
    final color = kindColor(item.kind, theme.brightness);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'heard at ${clock(surfaced.heardAt)} · matched by sound',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    final body = switch (item) {
      PhotoItem(:final reference) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: theme.colorScheme.surfaceContainerHighest,
              height: 190,
              child: Image(
                image: ResizeImage(
                  vm.imageFor(reference),
                  width: 900,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(kindIcon(item.kind), size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(item.title, style: theme.textTheme.titleSmall),
              ),
            ],
          ),
        ],
      ),
      NoteItem(:final title, :final body) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _KindBadge(kind: MultimodalRagKind.note, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  body,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      MemoItem(:final title, :final duration) => Row(
        children: [
          MemoPlayButton(vm: vm, memo: item, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title · ${clock(duration)}',
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  'A memo about the same thing — found by its sound',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    };
    return _Pulse(
      pulses: surfaced.pulses,
      color: color,
      child: Container(
        key: Key('multimodal-rag-surfaced-${item.id}'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [chip, const SizedBox(height: 10), body],
        ),
      ),
    );
  }
}

/// Glows briefly whenever [pulses] goes up.
class _Pulse extends StatefulWidget {
  const _Pulse({
    required this.pulses,
    required this.color,
    required this.child,
  });

  final int pulses;
  final Color color;
  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didUpdateWidget(_Pulse old) {
    super.didUpdateWidget(old);
    if (widget.pulses > old.pulses) unawaited(_controller.forward(from: 0));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final t = math.sin(_controller.value * math.pi);
      return Transform.scale(
        scale: 1 + 0.025 * t,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              if (t > 0)
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.45 * t),
                  blurRadius: 24 * t,
                  spreadRadius: 2 * t,
                ),
            ],
          ),
          child: child,
        ),
      );
    },
  );
}

/// The question Gemma 4 heard, as a quote.
class _QuestionQuote extends StatelessWidget {
  const _QuestionQuote({
    super.key,
    required this.question,
    required this.heardAt,
    required this.spoken,
  });

  final String question;
  final Duration? heardAt;
  final bool spoken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Appear(
      key: ValueKey(question),
      child: Container(
        key: const Key('multimodal-rag-live-question'),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(22),
            topRight: Radius.circular(22),
            bottomRight: Radius.circular(22),
            bottomLeft: Radius.circular(6),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.format_quote_rounded,
                  size: 30,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      if (heardAt case final at?) 'asked at ${clock(at)}',
                      'heard by Gemma 4',
                    ].join(' · '),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              spoken ? 'What was just said' : question,
              style: theme.textTheme.titleLarge?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin timeline of the meeting: a marker where each item surfaced, the
/// question, and the moment a meeting search found; tap one to jump there.
class _MeetingTimeline extends StatelessWidget {
  const _MeetingTimeline({
    required this.vm,
    required this.onSurfaced,
    required this.onQuestion,
    required this.onSearch,
  });

  final MultimodalRagViewModel vm;
  final void Function(SurfacedItem surfaced) onSurfaced;
  final VoidCallback onQuestion;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = vm.heard.inMilliseconds <= 0
        ? 1.0
        : vm.heard.inMilliseconds.toDouble();
    final hit = vm.meetingHit;
    final hitAt = hit != null && hit < vm.windows.length
        ? vm.windows[hit].start
        : null;
    final questionAt = vm.liveRun.heardAt;
    return Material(
      key: const Key('multimodal-rag-live-timeline'),
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hitAt != null)
              Text(
                '“${vm.meetingQuery}” · talked about at ${clock(hitAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.tertiary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            Row(
              children: [
                Text(
                  clock(vm.heard),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        double x(Duration at) =>
                            (at.inMilliseconds / total).clamp(0.0, 1.0) *
                            (constraints.maxWidth - 14);
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 14,
                              height: 2,
                              child: ColoredBox(color: scheme.outlineVariant),
                            ),
                            if (hitAt != null)
                              Positioned(
                                left: x(hitAt) - 3,
                                top: 3,
                                child: Container(
                                  key: const Key('multimodal-rag-live-found'),
                                  width: 20,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: scheme.tertiary,
                                      width: 2,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            for (final s in vm.surfaced)
                              Positioned(
                                left: x(s.heardAt),
                                top: 8,
                                child: GestureDetector(
                                  key: Key(
                                    'multimodal-rag-marker-${s.item.id}',
                                  ),
                                  onTap: () => onSurfaced(s),
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: kindColor(
                                        s.item.kind,
                                        theme.brightness,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              ),
                            if (questionAt != null)
                              Positioned(
                                left: x(questionAt),
                                top: 4,
                                child: GestureDetector(
                                  key: const Key(
                                    'multimodal-rag-marker-question',
                                  ),
                                  onTap: onQuestion,
                                  child: Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.question_mark_rounded,
                                      size: 14,
                                      color: scheme.onPrimary,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('multimodal-rag-meeting-search'),
                  tooltip: 'When did we talk about…',
                  onPressed: vm.liveState == LiveState.finished
                      ? onSearch
                      : null,
                  icon: const Icon(Icons.manage_search),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "When did we talk about …": pops the query.
class _MeetingSearchSheet extends StatefulWidget {
  const _MeetingSearchSheet();

  @override
  State<_MeetingSearchSheet> createState() => _MeetingSearchSheetState();
}

class _MeetingSearchSheetState extends State<_MeetingSearchSheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          Text('Search the meeting', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'By what was said, not by a transcript: EmbeddingGemma 2 compares '
            'your words with the sound of each moment.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('multimodal-rag-meeting-field'),
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (text) => Navigator.pop(context, text),
            decoration: InputDecoration(
              hintText: 'When did we talk about…',
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                key: const Key('multimodal-rag-meeting-go'),
                onPressed: () => Navigator.pop(context, _query.text),
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
