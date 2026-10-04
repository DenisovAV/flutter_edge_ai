import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/utils/file_name_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// The relative fetch suffix for a qwen3 bundle member — every qwen3 member
/// resolves same-repo, so the location is always a [TtsRelativeSuffix].
String qwen3SuffixOf(String fn) =>
    (TtsModelType.qwen3.fetchLocationFor(fn) as TtsRelativeSuffix).suffix;

void main() {
  test('matcha manifest lists its 8 runtime files', () {
    final m = TtsModelType.matcha.manifest;
    expect(m, contains('matcha_textenc_fp16.tflite'));
    expect(m, contains('matcha_decoder_fp16.tflite'));
    expect(m, contains('matcha_vocoder_fp16.tflite'));
    expect(m, contains('dp_g2p_matcha_fp16.tflite'));
    expect(m, contains('g2p_dict.txt.gz'));
    expect(m, contains('emb.bin'));
    expect(m, contains('config.json'));
    expect(m, contains('g2p_meta.json'));
    expect(m.length, 8);
  });

  test('every wired TtsModelType manifest (matcha, qwen3 — those whose '
      '.manifest does not throw) contains only plain basenames: a "/" would '
      'make MobileModelManager._restoreActiveTtsModel derive a different '
      'on-disk path than a fresh install did, silently breaking active-model '
      'restore after relaunch', () {
    for (final type in TtsModelType.values) {
      final List<String> manifest;
      try {
        manifest = type.manifest;
      } on UnimplementedError {
        continue; // Unwired family (kokoro/supertonic) — nothing to check.
      }
      for (final fn in manifest) {
        expect(
          fn.contains('/'),
          isFalse,
          reason: '$type manifest entry "$fn" must be a plain basename',
        );
      }
    }
  });

  test('unwired families throw UnimplementedError from manifest', () {
    expect(
      () => TtsModelType.kokoro.manifest,
      throwsA(isA<UnimplementedError>()),
    );
    expect(
      () => TtsModelType.supertonic.manifest,
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('qwen3 manifest lists its 9 runtime files (plain basenames — no '
      'config.json, no tables/voices subdirectory in the manifest itself; '
      'see fetchLocationFor for the network-fetch mapping)', () {
    final m = TtsModelType.qwen3.manifest;
    expect(m, contains('talker_int4.tflite'));
    expect(m, contains('mtp_fp32.tflite'));
    expect(m, contains('codec_decoder_fp32.tflite'));
    expect(m, contains('tokenizer.json'));
    expect(m, contains('text_embedding_fp16.npy'));
    expect(m, contains('text_projection_fp32.npz'));
    expect(m, contains('codec_embedding_fp32.npy'));
    expect(m, contains('mtp_embeddings_fp16.npy'));
    expect(m, contains('demo_speaker.npy'));
    expect(m.length, 9);
    expect(m, isNot(contains('config.json')));
    for (final fn in m) {
      expect(fn.contains('/'), isFalse, reason: '$fn must be a plain basename');
    }
  });

  test(
    'qwen3 fetchLocationFor maps the 4 embedding tables + demo voice to their '
    'HF tables/voices subdirectory; the other 4 members map to themselves — '
    'all as relative suffixes (qwen3 has no cross-repo members)',
    () {
      expect(
        TtsModelType.qwen3.fetchLocationFor('text_embedding_fp16.npy'),
        const TtsRelativeSuffix('tables/text_embedding_fp16.npy'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('text_projection_fp32.npz'),
        const TtsRelativeSuffix('tables/text_projection_fp32.npz'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('codec_embedding_fp32.npy'),
        const TtsRelativeSuffix('tables/codec_embedding_fp32.npy'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('mtp_embeddings_fp16.npy'),
        const TtsRelativeSuffix('tables/mtp_embeddings_fp16.npy'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('demo_speaker.npy'),
        const TtsRelativeSuffix('voices/demo_speaker.npy'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('talker_int4.tflite'),
        const TtsRelativeSuffix('talker_int4.tflite'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('mtp_fp32.tflite'),
        const TtsRelativeSuffix('mtp_fp32.tflite'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('codec_decoder_fp32.tflite'),
        const TtsRelativeSuffix('codec_decoder_fp32.tflite'),
      );
      expect(
        TtsModelType.qwen3.fetchLocationFor('tokenizer.json'),
        const TtsRelativeSuffix('tokenizer.json'),
      );
    },
  );

  test('fetchLocationFor is the identity relative mapping for every other '
      'TtsModelType (matcha has no subdirectories)', () {
    for (final fn in TtsModelType.matcha.manifest) {
      expect(TtsModelType.matcha.fetchLocationFor(fn), TtsRelativeSuffix(fn));
    }
  });

  test('inflect fetchLocationFor: the 4 reused Matcha G2P files resolve to an '
      'ABSOLUTE pinned-revision Matcha URL (TtsAbsoluteUrl); its own 2 '
      'tflites stay relative bare basenames', () {
    const g2pFiles = {
      'config.json',
      'g2p_dict.txt.gz',
      'dp_g2p_matcha_fp16.tflite',
      'g2p_meta.json',
    };
    for (final fn in TtsModelType.inflect.manifest) {
      final location = TtsModelType.inflect.fetchLocationFor(fn);
      if (g2pFiles.contains(fn)) {
        expect(
          location,
          TtsAbsoluteUrl(
            'https://huggingface.co/litert-community/Matcha-TTS/resolve/'
            'ee32148115e2dd25913f70b1d71b587c73e0866e/$fn',
          ),
        );
      } else {
        expect(location, TtsRelativeSuffix(fn));
      }
    }
  });

  test('flat<->url round trip (I5): building a qwen3 spec with sourceFor '
      'wired through fetchLocationFor (as TtsInstallationBuilder does) '
      'produces '
      'TtsBundleFiles whose prefsKey set is EXACTLY the manifest — the '
      "tables/voices subdirectory in the fetch URL never leaks into the "
      'installed identity / artifactPaths key Qwen3TtsCore.load reads', () {
    final spec = TtsModelSpec.fromManifest(
      name: 'qwen3',
      ttsModelType: TtsModelType.qwen3,
      sourceFor: (fn) => ModelSource.network(
        'https://huggingface.co/litert-community/'
        'Qwen3-TTS-12Hz-0.6B-Base/resolve/main/'
        '${qwen3SuffixOf(fn)}',
      ),
    );
    final prefsKeys = spec.files.map((f) => f.prefsKey).toSet();
    expect(prefsKeys, TtsModelType.qwen3.manifest.toSet());
    expect(spec.files.length, 9);

    // The 4 table files + demo voice namespace to a flat qwen3__<basename>
    // filename — no embedded subdirectory made it through.
    final tablesFile = spec.files.firstWhere(
      (f) => f.prefsKey == 'text_embedding_fp16.npy',
    );
    expect(tablesFile.filename, 'qwen3__text_embedding_fp16.npy');
    final voiceFile = spec.files.firstWhere(
      (f) => f.prefsKey == 'demo_speaker.npy',
    );
    expect(voiceFile.filename, 'qwen3__demo_speaker.npy');
  });

  test('qwen3 minimumSizeBytes: .npy/.npz bundle members (incl. the small '
      'demo_speaker.npy voice) get the 1 KB floor; .tflite graphs keep the '
      'validator default (null)', () {
    final spec = TtsModelSpec.fromManifest(
      name: 'qwen3',
      ttsModelType: TtsModelType.qwen3,
      sourceFor: (fn) => ModelSource.network('https://x/${qwen3SuffixOf(fn)}'),
    );
    final byName = {for (final f in spec.files) f.prefsKey: f};

    expect(byName['text_embedding_fp16.npy']!.minimumSizeBytes, 1024);
    expect(byName['text_projection_fp32.npz']!.minimumSizeBytes, 1024);
    expect(byName['codec_embedding_fp32.npy']!.minimumSizeBytes, 1024);
    expect(byName['mtp_embeddings_fp16.npy']!.minimumSizeBytes, 1024);
    expect(byName['demo_speaker.npy']!.minimumSizeBytes, 1024);
    expect(byName['tokenizer.json']!.minimumSizeBytes, 1024);

    expect(byName['talker_int4.tflite']!.minimumSizeBytes, isNull);
    expect(byName['mtp_fp32.tflite']!.minimumSizeBytes, isNull);
    expect(byName['codec_decoder_fp32.tflite']!.minimumSizeBytes, isNull);
  });

  test(
    'fromManifest builds one source+file per manifest entry; type is tts',
    () {
      final spec = TtsModelSpec.fromManifest(
        name: 'matcha',
        ttsModelType: TtsModelType.matcha,
        sourceFor: (fn) => ModelSource.network('https://x/$fn'),
      );
      expect(spec.type, ModelManagementType.tts);
      expect(spec.sources.length, 8);
      expect(spec.files.length, 8);
      expect(spec.files.every((f) => f.isRequired), isTrue);
      expect(spec.ttsModelType, TtsModelType.matcha);
    },
  );

  test('minimumSizeBytes: small aux files get a 1 KB floor, .tflite graphs '
      'keep the validator default (null)', () {
    final spec = TtsModelSpec.fromManifest(
      name: 'matcha',
      ttsModelType: TtsModelType.matcha,
      sourceFor: (fn) => ModelSource.network('https://x/$fn'),
    );
    final byName = {for (final f in spec.files) f.prefsKey: f};

    expect(byName['emb.bin']!.minimumSizeBytes, 1024);
    expect(byName['g2p_dict.txt.gz']!.minimumSizeBytes, 1024);
    expect(byName['config.json']!.minimumSizeBytes, 1024);
    expect(byName['g2p_meta.json']!.minimumSizeBytes, 1024);

    expect(byName['matcha_textenc_fp16.tflite']!.minimumSizeBytes, isNull);
    expect(byName['matcha_decoder_fp16.tflite']!.minimumSizeBytes, isNull);
    expect(byName['matcha_vocoder_fp16.tflite']!.minimumSizeBytes, isNull);
    expect(byName['dp_g2p_matcha_fp16.tflite']!.minimumSizeBytes, isNull);
  });

  test('value equality', () {
    ModelSource src(String fn) => ModelSource.network('https://x/$fn');
    final a = TtsModelSpec.fromManifest(
      name: 'm',
      ttsModelType: TtsModelType.matcha,
      sourceFor: src,
    );
    final b = TtsModelSpec.fromManifest(
      name: 'm',
      ttsModelType: TtsModelType.matcha,
      sourceFor: src,
    );
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
  });

  test('filename is namespaced by ttsModelType; prefsKey stays the plain '
      'manifest name (flutter_edge_ai_speech TtsModelProfile contract)', () {
    final spec = TtsModelSpec.fromManifest(
      name: 'matcha',
      ttsModelType: TtsModelType.matcha,
      sourceFor: (fn) => ModelSource.network('https://x/$fn'),
    );
    final configFile = spec.files.firstWhere(
      (f) => f.prefsKey == 'config.json',
    );
    expect(configFile.filename, 'matcha__config.json');
    expect(configFile.prefsKey, 'config.json');
  });

  test('restore-safe: reconstructing from FileSource paths whose basenames are '
      'ALREADY namespaced (as MobileModelManager._restoreActiveTtsModel does '
      "on relaunch) must not re-namespace .filename, and must denamespace "
      ".prefsKey back to the plain manifest name", () {
    final spec = TtsModelSpec.fromManifest(
      name: 'matcha',
      ttsModelType: TtsModelType.matcha,
      sourceFor: (fn) =>
          FileSource('/docs/${FileNameUtils.namespaced('matcha', fn)}'),
    );
    final configFile = spec.files.firstWhere(
      (f) => f.prefsKey == 'config.json',
    );
    // No double-prefix (matcha__matcha__config.json).
    expect(configFile.filename, 'matcha__config.json');
    // prefsKey stays plain so flutter_edge_ai_speech's
    // paths[profile.configFile] lookup (keyed by 'config.json') still
    // resolves — this is the regression guard for the restore path.
    expect(configFile.prefsKey, 'config.json');
  });

  test('qwen3 restore-safe: MobileModelManager._restoreActiveTtsModel derives '
      'namespaced paths DIRECTLY from the raw manifest string (no URL '
      'involved) — this must land on the SAME namespaced filename a fresh '
      'network install produces via fetchLocationFor, for every one of the 4 '
      'table + 1 voice member whose fetch URL has a tables/voices '
      'subdirectory the plain manifest entry does not', () {
    final installed = TtsModelSpec.fromManifest(
      name: 'qwen3',
      ttsModelType: TtsModelType.qwen3,
      sourceFor: (fn) => ModelSource.network('https://x/${qwen3SuffixOf(fn)}'),
    );
    for (final fn in TtsModelType.qwen3.manifest) {
      // Mirrors _restoreActiveTtsModel's `FileNameUtils.namespaced(modelId,
      // fn)` — computed from the raw manifest entry, independent of any URL.
      final restoreDerived = FileNameUtils.namespaced('qwen3', fn);
      final installDerived = installed.files
          .firstWhere((f) => f.prefsKey == fn)
          .filename;
      expect(
        restoreDerived,
        installDerived,
        reason:
            'restore would look for "$restoreDerived" but install wrote '
            '"$installDerived" — active TTS model restore would silently '
            'fail to find "$fn" after relaunch',
      );
    }
  });

  test('two different ttsModelTypes namespace the same generic basename '
      'distinctly (the latent config.json/emb.bin collision)', () {
    final matcha = TtsModelSpec.fromManifest(
      name: 'matcha',
      ttsModelType: TtsModelType.matcha,
      sourceFor: (fn) => ModelSource.network('https://x/$fn'),
    );
    final matchaConfig = matcha.files.firstWhere(
      (f) => f.prefsKey == 'config.json',
    );
    expect(matchaConfig.filename, 'matcha__config.json');
    // kokoro/supertonic throw from .manifest today (UnimplementedError) —
    // this asserts the NAMESPACING MECHANISM would disambiguate a
    // matching filename, using the modelId directly rather than
    // requiring a wired kokoro manifest.
    expect(
      FileNameUtils.namespaced(TtsModelType.kokoro.name, 'config.json'),
      isNot(equals(matchaConfig.filename)),
    );
  });
}
