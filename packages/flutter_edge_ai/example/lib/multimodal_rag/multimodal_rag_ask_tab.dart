part of 'multimodal_rag_widgets.dart';

class AskTab extends StatelessWidget {
  const AskTab({
    super.key,
    required this.vm,
    required this.controller,
    required this.onAsk,
    required this.onOpenList,
  });

  final MultimodalRagViewModel vm;
  final TextEditingController controller;
  final void Function(String text) onAsk;
  final OpenModelList onOpenList;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final llm = vm.setup?.llm;
    final run = vm.askRun;
    return ListenableBuilder(
      listenable: run,
      builder: (context, _) => ListView(
        key: const Key('multimodal-rag-ask'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _ErrorBanner(vm: vm),
          if (llm == null)
            _Notice(
              icon: Icons.auto_awesome_outlined,
              text:
                  'Answers need a language model: install Gemma 4 E2B from '
                  'the Inference Models list.',
              action: 'Install',
              onAction: () => onOpenList(MultimodalRagModelList.llm),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('multimodal-rag-ask-field'),
                  controller: controller,
                  enabled: llm != null,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: onAsk,
                  decoration: InputDecoration(
                    hintText: 'Ask about your notes, photos and memos',
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: run.busy
                          ? IconButton.filledTonal(
                              key: const Key('multimodal-rag-ask-stop'),
                              tooltip: 'Stop',
                              onPressed: vm.stopAnswer,
                              icon: const Icon(Icons.stop_rounded),
                            )
                          : IconButton.filled(
                              key: const Key('multimodal-rag-ask-send'),
                              tooltip: 'Ask',
                              onPressed: llm == null
                                  ? null
                                  : () => onAsk(controller.text),
                              icon: const Icon(Icons.arrow_upward_rounded),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _VoiceButton(vm: vm, enabled: llm?.hearsAudio ?? false),
            ],
          ),
          const SizedBox(height: 12),
          // Suggestions until the first question; then the conversation.
          if (run.question == null)
            _QuestionSuggestions(onTap: llm == null ? null : onAsk),
          if (run.question case final question?) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: run.spoken != null
                  ? KeyedSubtree(
                      key: const Key('multimodal-rag-ask-voice-bubble'),
                      child: _VoiceBubble(key: ValueKey(run.spoken), run: run),
                    )
                  : Container(
                      key: const Key('multimodal-rag-ask-question'),
                      constraints: const BoxConstraints(maxWidth: 320),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(18),
                          topRight: Radius.circular(18),
                          bottomLeft: Radius.circular(18),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: Text(
                        question,
                        style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
            ),
            if (run.listening)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Listening — the question stays sound: EmbeddingGemma 2 '
                  'searches with it, Gemma 4 hears it.',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (run.sources.isNotEmpty) ...[
              const _SectionHeader('FROM YOUR LIBRARY'),
              _SourcesStrip(vm: vm, run: run),
            ],
            const SizedBox(height: 12),
            _AnswerCard(vm: vm, run: run),
          ],
        ],
      ),
    );
  }
}

/// Suggested questions, one per line: they are too long for chips.
class _QuestionSuggestions extends StatelessWidget {
  const _QuestionSuggestions({required this.onTap});

  final void Function(String text)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final (i, question) in kMultimodalRagQuestions.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                key: Key('multimodal-rag-question-$i'),
                borderRadius: BorderRadius.circular(16),
                onTap: onTap == null ? null : () => onTap!(question),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.north_east,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          question,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Ask by voice: the microphone, or the bundled spoken question played as if
/// it came from it.
class _VoiceButton extends StatelessWidget {
  const _VoiceButton({required this.vm, required this.enabled});

  final MultimodalRagViewModel vm;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (vm.recordingQuestion) {
      return IconButton.filled(
        key: const Key('multimodal-rag-ask-voice-stop'),
        tooltip: 'Ask',
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
        onPressed: vm.stopVoiceQuestion,
        icon: const Icon(Icons.stop_rounded),
      );
    }
    return PopupMenuButton<void>(
      key: const Key('multimodal-rag-ask-voice'),
      tooltip: 'Ask by voice',
      enabled: enabled && !vm.askRun.busy,
      icon: const Icon(Icons.mic_none),
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          key: const Key('multimodal-rag-ask-voice-mic'),
          onTap: vm.startVoiceQuestion,
          child: const Text('Speak a question'),
        ),
        PopupMenuItem<void>(
          key: const Key('multimodal-rag-ask-voice-sample'),
          onTap: vm.askSampleByVoice,
          child: const Text('Play a sample spoken question'),
        ),
      ],
    );
  }
}
