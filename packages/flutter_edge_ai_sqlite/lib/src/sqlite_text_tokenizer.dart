/// How the SQLite store splits text into searchable terms for text search
/// (`VectorStoreSpec.enableTextSearch`): an FTS5 tokenizer.
///
/// Fixed when a location's text index is created. Opening that location later
/// with a different tokenizer fails with a `VectorStoreException`; leaving
/// [SqliteVectorStoreProvider.textTokenizer] null uses whatever the location
/// was created with.
final class SqliteTextTokenizer {
  const SqliteTextTokenizer._(this.fts5);

  /// Words split on Unicode spaces and punctuation, case- and
  /// diacritic-insensitive (`café` matches `cafe`), no stemming. Suits any
  /// language that separates words with spaces. The default.
  static const unicode61 = SqliteTextTokenizer._(
    'unicode61 remove_diacritics 2',
  );

  /// [unicode61] plus English Porter stemming (`running` matches `run`).
  static const porter = SqliteTextTokenizer._(
    'porter unicode61 remove_diacritics 2',
  );

  /// Overlapping three-character sequences: matches substrings, and text in
  /// languages written without spaces (Chinese, Japanese). Case-insensitive;
  /// a query term shorter than three characters matches nothing.
  static const trigram = SqliteTextTokenizer._('trigram');

  /// The FTS5 `tokenize` argument.
  final String fts5;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SqliteTextTokenizer && other.fts5 == fts5;

  @override
  int get hashCode => fts5.hashCode;

  @override
  String toString() => 'SqliteTextTokenizer($fts5)';
}
