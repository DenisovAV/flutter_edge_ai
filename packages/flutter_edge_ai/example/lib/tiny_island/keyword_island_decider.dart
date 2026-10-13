import 'island_catalog.dart';
import 'island_decider.dart';
import 'island_scoring.dart';

/// A model-free [IslandDecider] for tests: scores each action by word overlap
/// (Dice coefficient) between the request and the action's examples and
/// description. Deterministic and instant; it knows no synonyms and no other
/// language than the examples', which is exactly what the embedding Decider
/// is there to fix.
final class KeywordIslandDecider implements IslandDecider {
  KeywordIslandDecider(
    List<IslandAction> catalog, {
    this.threshold = 0.5,
    this.minMargin = 0.0001,
  }) : _phrases = {
         for (final action in catalog)
           action.id: [
             for (final text in [...action.examples, action.description])
               _words(text),
           ],
       };

  final Map<String, List<Set<String>>> _phrases;
  final double threshold;
  final double minMargin;
  bool _closed = false;

  @override
  String get name => 'Keyword match (test fake)';

  @override
  String? get backend => null;

  @override
  int get optionCount => _phrases.length;

  @override
  Future<IslandDecision> decide(String request) async {
    if (_closed) throw StateError('The decider is closed.');
    final watch = Stopwatch()..start();
    final words = _words(request);
    final scores = <String, double>{
      for (final MapEntry(key: id, value: phrases) in _phrases.entries)
        id: phrases.fold(0.0, (best, phrase) {
          final dice = _dice(words, phrase);
          return dice > best ? dice : best;
        }),
    };
    return rankIslandOptions(
      scores: scores,
      threshold: threshold,
      minMargin: minMargin,
      temperature: 0.1,
      embedTime: Duration.zero,
      scoreTime: watch.elapsed,
    );
  }

  @override
  Future<void> close() async => _closed = true;

  static const _stopWords = {'the', 'a', 'an', 'to', 'please', 'of', 'on'};

  static Set<String> _words(String text) => {
    for (final match in RegExp(
      r'[\p{L}\p{N}]+',
      unicode: true,
    ).allMatches(text.toLowerCase()))
      if (!_stopWords.contains(match[0])) match[0]!,
  };

  static double _dice(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final shared = a.intersection(b).length;
    return 2 * shared / (a.length + b.length);
  }
}
