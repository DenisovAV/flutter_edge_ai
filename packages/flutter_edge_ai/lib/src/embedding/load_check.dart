// The load-time check of what an engine reported against what the caller
// declared (R5 §4.2 step 5, D4). Pure; both hosts run it right after
// EmbeddingPass.load(), so an engine that cannot serve a declared modality is
// refused at load — once, with one error type for every engine — instead of on
// the first request.

import 'embedding_exceptions.dart';
import 'embedding_modality.dart';
import 'embedding_pass.dart';

/// Checks [info] against [declaredMedia] and returns the model's modalities:
/// the declared media plus text when the engine has a text tower.
///
/// Throws [EmbeddingLoadException] when the dimension is not positive; when a
/// declared `maxInputTokens` is not positive; when a declared modality is not
/// one the engine serves for this file; when the model would accept nothing
/// (no text tower and no medium declared); and for an engine bug: a media
/// modality without a single format it decodes, or a format listed under the
/// other modality. [label] names the model file in the message.
Set<EmbeddingModality> checkLoadedPass(
  EmbeddingPassInfo info,
  Set<EmbeddingModality> declaredMedia, {
  required String engine,
  required String label,
}) {
  if (info.dimension <= 0) {
    throw EmbeddingLoadException(
      '$engine reported dimension ${info.dimension} for $label; a model must '
      'produce vectors of positive length.',
      engine: engine,
    );
  }
  final maxInputTokens = info.maxInputTokens;
  if (maxInputTokens != null && maxInputTokens <= 0) {
    throw EmbeddingLoadException(
      '$engine reported maxInputTokens $maxInputTokens for $label; a limit '
      'must be positive (null when the file declares none).',
      engine: engine,
    );
  }
  for (final (formats, modality) in [
    (info.imageFormats, EmbeddingModality.image),
    (info.audioFormats, EmbeddingModality.audio),
  ]) {
    final misfiled = formats.where((f) => f.modality != modality);
    if (misfiled.isNotEmpty) {
      throw EmbeddingLoadException(
        '$engine lists ${misfiled.map((f) => f.name).join(', ')} among the '
        '${modality.name} formats it decodes for $label (an engine bug).',
        engine: engine,
      );
    }
  }
  for (final modality in declaredMedia) {
    if (modality == EmbeddingModality.text) continue;
    if (!info.modalities.contains(modality)) {
      throw EmbeddingLoadException(
        '$engine cannot embed ${_plural(modality)} for $label: the engine '
        'serves ${_describe(info.modalities)} for this file.',
        engine: engine,
      );
    }
  }
  if (info.modalities.contains(EmbeddingModality.image) &&
      info.imageFormats.isEmpty) {
    throw EmbeddingLoadException(
      '$engine reports image support for $label but no image format it '
      'decodes (an engine bug).',
      engine: engine,
    );
  }
  if (info.modalities.contains(EmbeddingModality.audio) &&
      info.audioFormats.isEmpty) {
    throw EmbeddingLoadException(
      '$engine reports audio support for $label but no audio format it '
      'decodes (an engine bug).',
      engine: engine,
    );
  }
  final modalities = Set<EmbeddingModality>.unmodifiable({
    if (info.modalities.contains(EmbeddingModality.text))
      EmbeddingModality.text,
    for (final modality in declaredMedia)
      if (modality != EmbeddingModality.text) modality,
  });
  if (modalities.isEmpty) {
    final media = [
      if (info.modalities.contains(EmbeddingModality.image)) 'supportImage',
      if (info.modalities.contains(EmbeddingModality.audio)) 'supportAudio',
    ];
    throw EmbeddingLoadException(
      '$engine has no text tower for $label, and no medium was declared, so '
      'the model would accept nothing.'
      '${media.isEmpty ? '' : ' Declare what it embeds: ${media.join(' or ')}.'}',
      engine: engine,
    );
  }
  return modalities;
}

String _plural(EmbeddingModality modality) => switch (modality) {
  EmbeddingModality.text => 'text',
  EmbeddingModality.image => 'images',
  EmbeddingModality.audio => 'audio',
};

String _describe(Set<EmbeddingModality> modalities) => modalities.isEmpty
    ? 'nothing'
    : [
        for (final m in EmbeddingModality.values)
          if (modalities.contains(m)) _plural(m),
      ].join(' and ');
