import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmModels, LiteRtLmVariant;

import '../translation/prompt_strategy.dart';
import '../translation/translate_gemma_xml_strategy.dart';
import 'base_model.dart';

/// Translator models (TranslateGemma and any future single-shot translators).
///
/// TranslateGemma 4B is a Gemma 3 fine-tune so it runs through the same
/// `InferenceModel.createSession()` path as any chat model — only the prompt
/// format differs (carried by `promptStrategy`). The `.litertlm` files come
/// from a community conversion at
/// `barakplasma/translategemma-4b-it-android-task-quantized` because Google
/// only ships a `-web.task` for browsers; mobile/desktop bundles are not
/// officially available yet (see HF discussion #5 on the source repo).
///
/// CPU-only, but not because anything aborts. Measured on an M4 Pro (Metal)
/// against both artifacts below: `engine_create` succeeds, `activeBackend`
/// reports `gpu`, generation runs — and emits nothing but `<pad>` until it hits
/// the context limit, while the same bundle, prompt and code answer correctly
/// on `PreferredBackend.cpu`. A stock `gemma-4-E2B-it.litertlm` on the same
/// machine and code path is correct on GPU, so it is not the Metal path in
/// general, and the two artifacts use different quantization recipes, which
/// rules out the bit width. Reported upstream at LiteRT-LM#1748.
///
/// An earlier version of this note said the float32 `EMBEDDING_LOOKUP` layout
/// makes the GPU partitioner abort. Nothing aborts in those runs, so that
/// description does not match these bundles.
// The model registry's builds (LiteRtLmModels), as functions: a variant is
// read through a getter, which is not a constant. Its GPU is withheld (the
// model writes only <pad> there, LiteRT-LM#1748), so it runs on the CPU.
LiteRtLmVariant _int4() => LiteRtLmModels.translategemma4bIt.int4;
LiteRtLmVariant _int8() => LiteRtLmModels.translategemma4bIt.int8;

enum TranslateModel implements TranslateModelInterface {
  /// INT4 quantization, ~2 GB. Recommended default — loads faster and fits
  /// in 6 GB free RAM on modern phones.
  translateGemma4Int4(
    variant: _int4,
    displayName: 'TranslateGemma 4B (int4)',
    size: '1.87GB',
    preferredBackend: PreferredBackend.cpu,
    maxTokens: 1024,
  ),

  /// Dynamic INT8, ~4 GB. Better translation quality; needs 8 GB free RAM.
  translateGemma4Int8(
    variant: _int8,
    displayName: 'TranslateGemma 4B (int8)',
    size: '4GB',
    preferredBackend: PreferredBackend.cpu,
    maxTokens: 1024,
  );

  const TranslateModel({
    required LiteRtLmVariant Function() variant,
    required this.displayName,
    required this.size,
    required this.preferredBackend,
    required this.maxTokens,
  }) : _variant = variant;

  final LiteRtLmVariant Function() _variant;

  /// The registry build this entry installs.
  LiteRtLmVariant get catalogVariant => _variant();

  @override
  String get url => _variant().file.url;

  @override
  String get filename => _variant().file.installFilename;

  @override
  final String displayName;

  @override
  final String size;

  @override
  bool get needsAuth => _variant().file.gated;

  @override
  final PreferredBackend preferredBackend;

  @override
  final int maxTokens;

  @override
  String get name => toString().split('.').last;

  @override
  ModelKind get kind => ModelKind.translation;

  @override
  String? get licenseUrl =>
      'https://huggingface.co/barakplasma/translategemma-4b-it-android-task-quantized';

  /// Gemma-3 fine-tune — uses the same Jinja chat template family.
  @override
  ModelType get modelType => ModelType.gemmaIt;

  ModelFileType get fileType => ModelFileType.litertlm;

  @override
  TranslationPromptStrategy get promptStrategy =>
      const TranslateGemmaXmlPromptStrategy();
}
