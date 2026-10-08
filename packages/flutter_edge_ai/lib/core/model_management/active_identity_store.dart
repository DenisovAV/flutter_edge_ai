import 'dart:convert';

import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A model kind whose active identity is persisted across restarts.
///
/// Embedding has its own versioned record (`ActiveEmbeddingIdentityRecord`)
/// and is not listed here.
enum ActiveIdentityKind {
  inference(PreferencesKeys.activeInferenceIdentity, [
    PreferencesKeys.activeInferenceModelType,
    PreferencesKeys.activeInferenceFileType,
    PreferencesKeys.activeInferenceFilename,
    PreferencesKeys.activeInferenceSource,
  ]),
  stt(PreferencesKeys.activeSttIdentity, [
    PreferencesKeys.activeSttFilename,
    PreferencesKeys.activeSttTokenizerFilename,
    PreferencesKeys.activeSttModelType,
    PreferencesKeys.activeSttSource,
    PreferencesKeys.activeSttTokenizerSource,
  ]),
  tts(PreferencesKeys.activeTtsIdentity, [
    PreferencesKeys.activeTtsName,
    PreferencesKeys.activeTtsModelType,
  ]);

  const ActiveIdentityKind(this.key, this.fields);

  /// The key the whole identity is stored under.
  final String key;

  /// The field names, which are also the per-field keys older releases wrote.
  final List<String> fields;
}

/// Reads and writes an active model identity as one JSON object under one
/// key.
///
/// The identity used to be one key per field, each a separate write. A
/// process that died between them left a mix: a restart then rebuilt one
/// model's weights with another model's tokenizer and type. One
/// `setString` cannot be interrupted halfway.
abstract final class ActiveIdentityStore {
  /// The identity of [kind], or null when none is stored.
  ///
  /// Prefers the one-key record. Without it, falls back to the per-field keys
  /// older releases wrote, so an upgrade keeps the active model; those can be
  /// a mix, which the caller has to check (see [sttModelMatchesSource]).
  static Map<String, String>? read(
    SharedPreferences prefs,
    ActiveIdentityKind kind,
  ) {
    final encoded = prefs.getString(kind.key);
    if (encoded != null) {
      final decoded = _decode(encoded);
      if (decoded == null) {
        edgeAiLog(
          '[ActiveIdentityStore] unreadable ${kind.name} identity — ignored',
        );
      }
      return decoded;
    }
    final legacy = <String, String>{
      for (final field in kind.fields) field: ?prefs.getString(field),
    };
    return legacy.isEmpty ? null : legacy;
  }

  /// Stores [fields] as the identity of [kind] in one write, then drops the
  /// per-field keys of older releases. Throws [StateError] if the write fails.
  static Future<void> write(
    SharedPreferences prefs,
    ActiveIdentityKind kind,
    Map<String, String> fields,
  ) async {
    if (!await prefs.setString(kind.key, jsonEncode(fields))) {
      throw StateError(
        'Failed to persist the active ${kind.name} model identity.',
      );
    }
    // The record above is authoritative from now on and a leftover per-field
    // key is never read again, so removing them is cleanup: a failure here
    // must not report the committed identity as unwritten.
    for (final field in kind.fields) {
      try {
        await prefs.remove(field);
      } catch (e) {
        edgeAiLog('[ActiveIdentityStore] old key $field not removed: $e');
      }
    }
  }

  /// Removes the identity of [kind], in both forms. Throws [StateError] when
  /// a removal fails: whatever is left would restore the model on the next
  /// launch, the per-field keys included when there is no record.
  ///
  /// The per-field keys go first, while the record still masks them, and the
  /// record last: a clear cut short then leaves the identity it was clearing,
  /// never stale per-field keys from an older write in its place.
  static Future<void> clear(
    SharedPreferences prefs,
    ActiveIdentityKind kind,
  ) async {
    for (final key in [...kind.fields, kind.key]) {
      if (!await prefs.remove(key)) {
        throw StateError(
          'Failed to clear the active ${kind.name} model identity ($key).',
        );
      }
    }
  }

  /// Whether the STT model source stored next to [modelFilename] names that
  /// file. Older releases wrote the identity key by key — filename, tokenizer,
  /// type, then the sources — so a process that died in between left the new
  /// filename next to the previous model's source. Without a stored source
  /// there was no earlier identity to mix with.
  static bool sttModelMatchesSource(
    String modelFilename,
    String? encodedModelSource,
  ) {
    if (encodedModelSource == null) return true;
    final source = ModelSource.tryDecode(encodedModelSource);
    return source != null &&
        SttModelFile.fromSource(source).filename == modelFilename;
  }

  static Map<String, String>? _decode(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return null;
      return {
        for (final entry in decoded.entries)
          if (entry.value case final String value) entry.key: value,
      };
    } on FormatException {
      return null;
    }
  }
}
