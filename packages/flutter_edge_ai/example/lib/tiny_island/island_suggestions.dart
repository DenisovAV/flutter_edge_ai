/// Requests the screen offers as chips. Paraphrases on purpose: none is an
/// option's example or description (a chip that repeats one scores like a
/// lookup, not like understanding), nor a held-out calibration request; a
/// unit test keeps it that way. The last one is out of scope: the Decider
/// should abstain.
///
/// Chosen among paraphrases the Decider answers with EmbeddingGemma 2 Text
/// (270M) on a CPU: calibrated for a 5 % error budget, it declines more than
/// a quarter of in-scope paraphrases ("let night fall", "zoom in on the
/// cottage" among them), which a chip should not show off. Typed requests
/// get no such help.
const List<String> islandSuggestions = [
  'wander over to the well',
  'crack open the treasure chest',
  'the flowers need some water',
  'turn the lantern on',
  'time for a sunset',
  'get a fire going',
  'I would like some rain',
  'rest your legs on the bench',
  'do a dance at the fire pit',
  'climb up the oak tree',
  'lauf zum Baum',
  'what is the capital of France?',
];
