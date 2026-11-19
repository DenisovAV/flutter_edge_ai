// The decision a `.litertlm` model was trained on: litetune's
// `litetune.decision` section, read with litertlm_dart's generic section
// reader. The name and the payload's meaning are litetune's contract with
// core's decider, so they live here.

import 'dart:convert';
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart' show readBundleGenericData;

/// The `name` item of the section litetune's `bundle` writes the decision a
/// model was trained on into (`decision_section.SECTION_NAME`).
const litetuneDecisionSectionName = 'litetune.decision';

/// The decision a `.litertlm` model file was trained on: the UTF-8 JSON
/// payload of its `litetune.decision` section, or null when it has none. Reads
/// the container header and that one section, nothing else.
///
/// The section is a `GenericBinaryData` section whose `name` item is
/// `litetune.decision`, as litetune 0.5.0's `bundle` writes it; LiteRT-LM never
/// maps such a section, so it costs the model nothing. Throws
/// [FormatException] for a file that is not a `.litertlm` container this
/// reader understands, a section range outside it, more than one decision
/// section, and a payload that is not UTF-8.
Future<String?> readLitetuneDecisionSection(String modelPath) async {
  final bytes = await readBundleGenericData(
    modelPath,
    litetuneDecisionSectionName,
  );
  return bytes == null ? null : utf8.decode(bytes);
}

/// What reading a model file's decision gave, captured when the model is
/// loaded, so that a decider reads the file the engine loaded: the payload,
/// or null when the file has none, or why it could not be read.
final class LitetuneDecisionRead {
  const LitetuneDecisionRead._(this.payload, this.error);

  final String? payload;

  /// Why the file's decision could not be read; then [payload] is null.
  final FormatException? error;

  /// Reads [modelPath]'s decision. An I/O failure is captured as a
  /// [FormatException] too: the decision is the file's, unreadable either way.
  static Future<LitetuneDecisionRead> read(String modelPath) async {
    try {
      return LitetuneDecisionRead._(
        await readLitetuneDecisionSection(modelPath),
        null,
      );
    } on FormatException catch (e) {
      return LitetuneDecisionRead._(null, e);
    } on FileSystemException catch (e) {
      return LitetuneDecisionRead._(
        null,
        FormatException('the model file could not be read: $e'),
      );
    }
  }
}
