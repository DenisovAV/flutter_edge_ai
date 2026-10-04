/// Open/closed extension point for translation models.
///
/// Each TranslateGemma-style model has a different on-the-wire prompt format
/// (community `.litertlm` uses `<src>en</src><dst>fr</dst><text>...</text>`,
/// Google's official `-web.task` uses a natural-language system prompt, future
/// NLLB / MADLAD bundles use yet other shapes). Adding a new translator model
/// to the example app is a matter of writing a new subclass of this — no
/// switch-on-enum to edit anywhere.
abstract class TranslationPromptStrategy {
  const TranslationPromptStrategy();

  /// Build the single-shot prompt that gets fed to
  /// `InferenceModel.createSession()` + `addQueryChunk()`.
  ///
  /// [src] and [dst] are ISO 639-1 codes (`'en'`, `'fr'`, `'ja'`); strategies
  /// that need a different vocabulary (e.g. NLLB's `eng_Latn`) translate
  /// internally.
  String formatPrompt({
    required String src,
    required String dst,
    required String text,
  });

  /// Map from language code to human-readable name, used to populate the
  /// source/target dropdowns in `TranslateScreen`.
  ///
  /// Different translator models support different language sets —
  /// TranslateGemma lists 55, NLLB lists 202, MADLAD lists 400+. Returning
  /// the map per strategy keeps each translator self-describing.
  Map<String, String> get supportedLanguages;
}
