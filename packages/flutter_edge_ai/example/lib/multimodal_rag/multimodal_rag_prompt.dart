// What the language model is asked: an answer from the retrieved items as
// numbered sources, which the answer cites as [1], [2]; and, in Live, whether
// the last seconds of a meeting hold a question. Pure Dart; unit-tested in
// test/multimodal_rag_logic_test.dart.

import 'multimodal_rag_item.dart';

/// The system instruction of every answer. Measured on Gemma 4 E2B with the
/// receipt photo attached: without the TOTAL sentence it answered "How much
/// was the airport taxi?" with a single line of the receipt.
const kMultimodalRagSystemInstruction =
    'You answer questions about the user\'s own notes, voice memos and '
    'photos, using only the numbered sources; an attached image or recording '
    'is one of them. When asked what something cost, read the TOTAL line of '
    'the receipt, not a single item such as a fee. After each fact, cite its '
    'source number in square brackets, like [1]. If the sources do not '
    'contain the answer, say that you could not find it. Answer in one or two '
    'short sentences.';

/// A retrieved item as the language model gets it: numbered from 1, in rank
/// order. A photo or a memo is [attached] when its image or recording is
/// sent along.
typedef MultimodalRagSource = ({
  int number,
  MultimodalRagItem item,
  bool attached,
});

/// The user turn: the sources, then the question — or, when the question
/// was [spoken], where to hear it: it is the attached recording, and it is
/// never written out.
String buildMultimodalRagPrompt(
  String question,
  List<MultimodalRagSource> sources, {
  bool spoken = false,
}) {
  final lines = <String>['Sources:'];
  for (final source in sources) {
    final item = source.item;
    final n = source.number;
    lines.add(switch (item) {
      NoteItem(:final title, :final body) => '[$n] Note "$title": $body',
      PhotoItem() when source.attached => '[$n] Photo: the attached image',
      PhotoItem() => '[$n] Photo (not shown to you)',
      MemoItem() when source.attached =>
        '[$n] Voice memo: the attached recording',
      MemoItem() => '[$n] Voice memo (not played to you)',
    });
  }
  lines
    ..add('')
    ..add(
      spoken
          ? 'The question was asked out loud: it is the attached recording. '
                'Listen to it, then answer it from the sources.'
          : 'Question: ${question.trim()}',
    );
  return lines.join('\n');
}

/// The source numbers [answer] cites, in the order it first cites them.
/// Reads `[1]`, `[1, 3]` and `[1][2]`.
List<int> citedSources(String answer) {
  final cited = <int>[];
  for (final group in RegExp(r'\[([\d,\s]+)\]').allMatches(answer)) {
    for (final number in group.group(1)!.split(',')) {
      final n = int.tryParse(number.trim());
      if (n != null && !cited.contains(n)) cited.add(n);
    }
  }
  return cited;
}

/// What the language model is told about a meeting window it hears.
const kLiveListenInstruction =
    'You are listening to a work meeting a few seconds at a time.';

/// The question about one window, sent with its recording.
const kLiveListenPrompt =
    'Listen to this audio. Did the speaker ask a question? If yes, reply '
    'QUESTION: followed by the question. If not, reply NONE.';

/// The question a reply to [kLiveListenPrompt] names, or null for NONE — and
/// for a "question" that does not read as one (Gemma 4 sometimes names a
/// statement): it must end with a question mark or start like a question.
String? parseLiveQuestion(String reply) {
  final match = RegExp(
    r'QUESTION\s*:\s*(.+)',
    caseSensitive: false,
  ).firstMatch(reply.trim());
  final question = match?.group(1)?.trim().split('\n').first.trim();
  if (question == null || question.isEmpty) return null;
  if (question.toUpperCase().startsWith('NONE')) return null;
  final asks =
      question.endsWith('?') ||
      RegExp(
        r'^(wait,?\s+)?(how|what|when|where|who|whom|whose|why|which|do|does|'
        r'did|is|are|was|were|can|could|will|would|should|have|has)\b',
        caseSensitive: false,
      ).hasMatch(question);
  return asks ? question : null;
}
