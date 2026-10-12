/// What an embedding is for. Every engine prepends [prefix] to the TEXT part of
/// an input, native and web alike; media parts never get a prefix.
///
/// The strings are the distinct prompts of `google/embeddinggemma-2`'s
/// `config_sentence_transformers.json` (rev 914f7f89), plus [none] for raw
/// input. New values are APPENDED, so [retrievalQuery] and [retrievalDocument]
/// keep the indices they had in 2.1 and corpora indexed with earlier releases
/// stay valid. Adding a value breaks exhaustive switches in apps.
enum TaskType {
  /// A search query against documents embedded with [retrievalDocument].
  retrievalQuery,

  /// A document to be found by [retrievalQuery].
  retrievalDocument,

  /// Raw input: no prefix at all.
  none,

  /// A question whose answer is being searched for.
  questionAnswering,

  /// A claim to be checked against evidence.
  factChecking,

  /// A natural-language query for code.
  codeRetrieval,

  /// Text to be classified.
  classification,

  /// Text to be clustered.
  clustering,

  /// Text compared with other text for similarity.
  sentenceSimilarity;

  /// The prefix prepended to the text before tokenization. The single prefix
  /// function every engine uses (it fixed cross-platform drift on
  /// [retrievalQuery], #264, by construction).
  String get prefix => switch (this) {
    TaskType.retrievalQuery => 'task: search result | query: ',
    TaskType.retrievalDocument => 'title: none | text: ',
    TaskType.none => '',
    TaskType.questionAnswering => 'task: question answering | query: ',
    TaskType.factChecking => 'task: fact checking | query: ',
    TaskType.codeRetrieval => 'task: code retrieval | query: ',
    TaskType.classification => 'task: classification | query: ',
    TaskType.clustering => 'task: clustering | query: ',
    TaskType.sentenceSimilarity => 'task: sentence similarity | query: ',
  };
}
