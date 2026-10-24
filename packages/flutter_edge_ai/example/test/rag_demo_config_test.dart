import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/models/base_model.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/services/embedding_catalog_provenance.dart';
import 'package:flutter_edge_ai_example/utils/installed_model_lookup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every catalog embedder has a unique path-safe stable profile — '
      'except the EmbeddingGemma 2 bundles, whose text towers are one per '
      'backend', () {
    final ids = [
      for (final model in catalog.EmbeddingModel.values)
        if (!model.isLiteRtLmBundle) model.ragProfileId,
    ];
    final eg2 = {
      for (final model in catalog.EmbeddingModel.values)
        if (model.isLiteRtLmBundle && model.npuSoc == null) model.ragProfileId,
    };
    expect(eg2, hasLength(1), reason: 'one text id for every EG2 bundle (M7)');
    ids.add(eg2.single);
    // One per SoC: an NPU bundle's vectors are not the CPU bundle's.
    final npu = <String, String>{
      for (final model in catalog.EmbeddingModel.values)
        if (model.npuSoc case final soc?) soc: model.ragProfileId,
    };
    expect(npu.keys, [
      'SM8850',
      'SM8650',
      'QCS8275',
      'PTL',
      'Tensor_G6',
      'MT6991',
    ]);
    ids.addAll(npu.values);

    expect(ids.toSet(), hasLength(ids.length));
    for (final id in [
      ...ids,
      for (final model in catalog.EmbeddingModel.values)
        ?model.imageRagProfileId,
    ]) {
      expect(id, matches(RegExp(r'^[a-z0-9][a-z0-9._-]*$')));
      expect(id, isNot(contains('/')));
      expect(id, isNot(contains('resolve')));
    }
  });

  test('profile lookup matches both model and tokenizer sources', () {
    for (final model in catalog.EmbeddingModel.values) {
      expect(
        embeddingProfileIdForSpec(_catalogSpec(model)),
        model.ragProfileId,
      );
    }
  });

  test('profile lookup refuses custom and mixed-source models', () {
    final custom = EmbeddingModelSpec(
      name: 'custom',
      modelSource: ModelSource.file('/tmp/model.tflite'),
      tokenizerSource: ModelSource.file('/tmp/tokenizer.model'),
    );
    expect(embeddingProfileIdForSpec(custom), isNull);

    const catalogModel = catalog.EmbeddingModel.embeddingGemma256;
    final mixed = EmbeddingModelSpec(
      name: catalogModel.name,
      modelSource: ModelSource.network(catalogModel.url),
      tokenizerSource: ModelSource.asset('assets/models/sentencepiece.model'),
      modelFilename: catalogModel.filename,
      tokenizerFilename: catalogModel.tokenizerFilename,
    );
    expect(embeddingProfileIdForSpec(mixed), isNull);
  });

  test('remote artifacts use revision-qualified cache identities', () {
    final remoteModels = catalog.EmbeddingModel.values.where(
      (model) => model.sourceType == ModelSourceType.network,
    );
    expect(
      remoteModels.map((model) => model.filename).toSet(),
      hasLength(remoteModels.length),
    );
    final withTokenizer = remoteModels.where((m) => m.tokenizerUrl != null);
    expect(
      withTokenizer.map((model) => model.tokenizerFilename).toSet(),
      hasLength(withTokenizer.length),
    );
    for (final model in remoteModels) {
      expect(model.filename, contains('__rev-'));
      expect(model.filename, isNot(Uri.parse(model.url).pathSegments.last));
      final tokenizerUrl = model.tokenizerUrl;
      if (tokenizerUrl == null) continue;
      expect(model.tokenizerFilename, contains('__rev-'));
      expect(
        model.tokenizerFilename,
        isNot(Uri.parse(tokenizerUrl).pathSegments.last),
      );
    }
  });

  test('EmbeddingGemma 2 text is one pinned .litertlm bundle with the shared '
      'text profile', () {
    const eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
    expect(eg2.isLiteRtLmBundle, isTrue);
    expect(eg2.tokenizerUrl, isNull);
    expect(eg2.tokenizerFilename, isNull);
    expect(
      eg2.url,
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/'
      '9be6e8b90982095dc05c2bd162e4b954ee4dbac7/'
      'embeddinggemma-2-text-270m.litertlm',
    );
    expect(eg2.filename, endsWith('.litertlm'));
    expect(
      eg2.sha256,
      '2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb',
    );
    expect(eg2.needsAuth, isFalse);
    expect(eg2.dimension, 768);
    expect(
      eg2.ragProfileId,
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
    );
    // The installer builds a self-contained spec from it: one file.
    expect(_catalogSpec(eg2).isSelfContained, isTrue);
    expect(_catalogSpec(eg2).files, hasLength(1));
    expect(eg2.embedsImages, isFalse);
    expect(eg2.imageRagProfileId, isNull);
    // Every other entry is a two-file EG1/Gecko spec, or the 440m bundle.
    for (final model in catalog.EmbeddingModel.values) {
      if (model == eg2 ||
          model == catalog.EmbeddingModel.embeddingGemma2TextVision440m ||
          model == catalog.EmbeddingModel.embeddingGemma2TextVisionAudio740m ||
          model.npuSoc != null) {
        continue;
      }
      expect(model.isLiteRtLmBundle, isFalse, reason: model.name);
      expect(model.embedsImages, isFalse, reason: model.name);
      expect(model.embedsAudio, isFalse, reason: model.name);
    }
  });

  test('EmbeddingGemma 2 Text + Vision is one pinned .litertlm bundle: the '
      'text id for text stores, the text id + -vis140 for image indexes', () {
    const vision = catalog.EmbeddingModel.embeddingGemma2TextVision440m;
    expect(vision.isLiteRtLmBundle, isTrue);
    expect(
      vision.url,
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-vision-440m-litert-lm/resolve/'
      'e301f74d5551b0c2641bd5cb4652a76239d5c5f8/'
      'embeddinggemma-2-text-vision-440m.litertlm',
    );
    expect(vision.filename, contains('__rev-e301f74d5551'));
    expect(
      vision.sha256,
      '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0',
    );
    expect(vision.needsAuth, isFalse);
    expect(vision.embedsImages, isTrue);
    expect(
      vision.ragProfileId,
      catalog.EmbeddingModel.embeddingGemma2Text270m.ragProfileId,
    );
    expect(
      vision.imageRagProfileId,
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-vis140',
    );
    expect(catalog.kExampleVisionTokensPerImage, 140);
    expect(_catalogSpec(vision).files, hasLength(1));
    expect(vision.embedsAudio, isFalse);
  });

  test('EmbeddingGemma 2 740M is one pinned, ungated .litertlm bundle that '
      'embeds images and audio, with the text id (and the text id + -vis140 '
      'for image indexes)', () {
    const audio = catalog.EmbeddingModel.embeddingGemma2TextVisionAudio740m;
    expect(audio.isLiteRtLmBundle, isTrue);
    expect(
      audio.url,
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-740m-litert-lm/resolve/'
      '24d962e906c7d332c6428e71c9676855024569e2/'
      'embeddinggemma-2-740m.litertlm',
    );
    expect(audio.filename, contains('__rev-24d962e906c7'));
    expect(
      audio.sha256,
      'e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c',
    );
    expect(audio.needsAuth, isFalse);
    expect(audio.embedsImages, isTrue);
    expect(audio.embedsAudio, isTrue);
    expect(
      audio.ragProfileId,
      catalog.EmbeddingModel.embeddingGemma2Text270m.ragProfileId,
    );
    expect(
      audio.imageRagProfileId,
      catalog.EmbeddingModel.embeddingGemma2TextVision440m.imageRagProfileId,
    );
    expect(_catalogSpec(audio).files, hasLength(1));
  });

  test('the per-SoC NPU bundles: pinned like the generic ones, loaded with '
      'npu, and an id of their own per SoC, shared by its 270m, 440m and '
      '740m', () {
    final npu = [
      for (final model in catalog.EmbeddingModel.values)
        if (model.npuSoc != null) model,
    ];
    expect(npu.map((m) => m.name), [
      'embeddingGemma2Text270mSm8850',
      'embeddingGemma2TextVision440mSm8850',
      'embeddingGemma2TextVisionAudio740mSm8850',
      'embeddingGemma2Text270mSm8650',
      'embeddingGemma2TextVision440mSm8650',
      'embeddingGemma2Text270mQcs8275',
      'embeddingGemma2TextVision440mQcs8275',
      'embeddingGemma2Text270mPtl',
      'embeddingGemma2TextVision440mPtl',
      'embeddingGemma2Text270mTensorG6',
      'embeddingGemma2TextVision440mTensorG6',
      'embeddingGemma2Text270mMt6991',
    ]);
    const cpuTextId = 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1';
    for (final model in npu) {
      final soc = model.npuSoc!;
      final vendor = switch (model.npuVendor) {
        catalog.EmbeddingNpuVendor.qualcomm => 'Qualcomm',
        catalog.EmbeddingNpuVendor.intel => 'Intel',
        catalog.EmbeddingNpuVendor.googleTensor => 'Google',
        catalog.EmbeddingNpuVendor.mediatek => 'MediaTek',
      };
      expect(
        vendor,
        soc == 'PTL'
            ? 'Intel'
            : soc.startsWith('Tensor_')
            ? 'Google'
            : soc.startsWith('MT')
            ? 'MediaTek'
            : 'Qualcomm',
        reason: model.name,
      );
      final repo = model.embedsAudio
          ? 'embeddinggemma-2-740m-litert-lm/resolve/'
                '24d962e906c7d332c6428e71c9676855024569e2/'
                'embeddinggemma-2-740m'
          : model.embedsImages
          ? 'embeddinggemma-2-text-vision-440m-litert-lm/resolve/'
                'e301f74d5551b0c2641bd5cb4652a76239d5c5f8/'
                'embeddinggemma-2-text-vision-440m'
          : 'embeddinggemma-2-text-270m-litert-lm/resolve/'
                '9be6e8b90982095dc05c2bd162e4b954ee4dbac7/'
                'embeddinggemma-2-text-270m';
      expect(
        model.url,
        'https://huggingface.co/litert-community/${repo}_${vendor}_$soc.litertlm',
        reason: model.name,
      );
      expect(model.isLiteRtLmBundle, isTrue);
      expect(model.needsAuth, isFalse);
      expect(model.sha256, hasLength(64));
      expect(model.filename, contains('_${vendor}_${soc}__rev-'));
      expect(model.embedderBackend, PreferredBackend.npu);
      expect(
        model.ragProfileId,
        '$cpuTextId-npu-${soc.toLowerCase()}',
        reason: 'NPU vectors never share the CPU id',
      );
      expect(
        catalog.embedderBackendForProfile(model.ragProfileId),
        PreferredBackend.npu,
      );
      if (model.embedsImages) {
        expect(
          model.imageRagProfileId,
          '$cpuTextId-npu-${soc.toLowerCase()}-vis140',
        );
        expect(
          catalog.embedderBackendForProfile(model.imageRagProfileId!),
          PreferredBackend.npu,
        );
      }
      expect(_catalogSpec(model).files, hasLength(1));
    }
    // Every CPU id is unchanged, and loads with the default backend.
    expect(
      catalog.EmbeddingModel.embeddingGemma2Text270m.ragProfileId,
      cpuTextId,
    );
    expect(
      catalog.EmbeddingModel.embeddingGemma2Text270m.embedderBackend,
      isNull,
    );
    expect(catalog.embedderBackendForProfile(cpuTextId), isNull);
    expect(catalog.embedderBackendForProfile('$cpuTextId-vis140'), isNull);
    // The SoC's 270m and 440m share one id; two SoCs never do.
    expect(
      catalog.EmbeddingModel.embeddingGemma2Text270mSm8850.ragProfileId,
      catalog.EmbeddingModel.embeddingGemma2TextVision440mSm8850.ragProfileId,
    );
    expect(
      catalog
          .EmbeddingModel
          .embeddingGemma2TextVisionAudio740mSm8850
          .imageRagProfileId,
      catalog
          .EmbeddingModel
          .embeddingGemma2TextVision440mSm8850
          .imageRagProfileId,
    );
    expect(
      catalog.EmbeddingModel.embeddingGemma2Text270mSm8850.ragProfileId,
      isNot(catalog.EmbeddingModel.embeddingGemma2Text270mQcs8275.ragProfileId),
    );
    // Intel Panther Lake: Hugging Face's lfs.oid pins, and the -npu-ptl id
    // its 270m and 440m share (byte-identical text towers).
    const ptl270m = catalog.EmbeddingModel.embeddingGemma2Text270mPtl;
    const ptl440m = catalog.EmbeddingModel.embeddingGemma2TextVision440mPtl;
    expect(ptl270m.ragProfileId, '$cpuTextId-npu-ptl');
    expect(ptl440m.ragProfileId, ptl270m.ragProfileId);
    expect(ptl440m.imageRagProfileId, '$cpuTextId-npu-ptl-vis140');
    expect(ptl270m.embedsImages, isFalse);
    expect(
      ptl270m.sha256,
      '048e219d702d23cf19cb9a75e7595e61e320bc61a3919e0cbf1a30dfb5cc64f4',
    );
    expect(
      ptl440m.sha256,
      '7f4c104b30ea6185516439aef534b84d9e7066366112506d5d8843e350fd08c9',
    );
  });

  test('the Qualcomm NPU bundles are listed on Android and Linux only, the '
      'Intel ones on Windows only, the Google Tensor ones on Android only', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final listed = catalog.listedEmbeddingModels.where(
        (m) => m.npuSoc != null,
      );
      final qualcomm =
          platform == TargetPlatform.android ||
          platform == TargetPlatform.linux;
      final intel = platform == TargetPlatform.windows;
      expect(
        listed.where((m) => m.npuVendor == catalog.EmbeddingNpuVendor.qualcomm),
        hasLength(qualcomm ? 7 : 0),
        reason: '$platform',
      );
      expect(
        listed.where(
          (m) => m.npuVendor == catalog.EmbeddingNpuVendor.googleTensor,
        ),
        hasLength(platform == TargetPlatform.android ? 2 : 0),
        reason: '$platform',
      );
      expect(
        listed.where((m) => m.npuVendor == catalog.EmbeddingNpuVendor.mediatek),
        hasLength(platform == TargetPlatform.android ? 1 : 0),
        reason: '$platform',
      );
      expect(
        listed.map((m) => m.name),
        intel
            ? ['embeddingGemma2Text270mPtl', 'embeddingGemma2TextVision440mPtl']
            : isNot(contains('embeddingGemma2Text270mPtl')),
        reason: '$platform',
      );
      expect(
        catalog.listedEmbeddingModels,
        containsAll([
          for (final m in catalog.EmbeddingModel.values)
            if (m.npuSoc == null) m,
        ]),
      );
    }
  });

  test('a restart restores the profile of the entry that was installed, also '
      'when another entry shares its profile id', () async {
    // The 270m and the 440m share the text id; the record names the 440m.
    const model = catalog.EmbeddingModel.embeddingGemma2TextVision440m;
    await persistVerifiedEmbeddingCatalogSelection(
      model,
      spec: _catalogSpec(model),
    );
    final restored = EmbeddingModelSpec(
      name: model.name,
      modelSource: ModelSource.file('/managed/${model.filename}'),
      modelFilename: model.filename,
    );
    expect(
      await resolveActiveEmbeddingCatalogProfile(spec: restored),
      model.ragProfileId,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(EmbeddingCatalogPreferencesKeys.activeProfileProvenance),
      isNotNull,
      reason: 'the record was not cleared',
    );
  });

  test('local asset has its own versioned install identities', () {
    const local = catalog.EmbeddingModel.localEmbeddingGemma256;
    const remote = catalog.EmbeddingModel.embeddingGemma256;
    final legacyModel = Uri.parse(remote.url).pathSegments.last;

    expect(local.filename, contains('__example-asset-v1'));
    expect(local.tokenizerFilename, contains('__example-asset-v1'));
    expect(local.filename, isNot(legacyModel));
    expect(local.filename, isNot(remote.filename));
    expect(local.tokenizerFilename, isNot(remote.tokenizerFilename));
  });

  test(
    'verified network install restores profile from native FileSources',
    () async {
      const model = catalog.EmbeddingModel.embeddingGemma256;
      final networkSpec = _catalogSpec(model);
      await persistVerifiedEmbeddingCatalogSelection(model, spec: networkSpec);

      final restored = EmbeddingModelSpec(
        name: model.name,
        modelSource: ModelSource.file('/managed/${model.filename}'),
        tokenizerSource: ModelSource.file(
          '/managed/${model.tokenizerFilename}',
        ),
        modelFilename: model.filename,
        tokenizerFilename: model.tokenizerFilename,
      );

      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: restored),
        model.ragProfileId,
      );
    },
  );

  test(
    'legacy basename cache is never relabeled with catalog provenance',
    () async {
      const model = catalog.EmbeddingModel.embeddingGemma256;
      await persistVerifiedEmbeddingCatalogSelection(
        model,
        spec: _catalogSpec(model),
      );
      final prefs = await SharedPreferences.getInstance();

      final oldModelFilename = Uri.parse(model.url).pathSegments.last;
      final oldTokenizerFilename =
          '${oldModelFilename.substring(0, oldModelFilename.lastIndexOf('.'))}__sentencepiece.model';
      final legacyRestored = EmbeddingModelSpec(
        name: oldModelFilename,
        modelSource: ModelSource.file('/legacy/$oldModelFilename'),
        tokenizerSource: ModelSource.file('/legacy/$oldTokenizerFilename'),
        modelFilename: oldModelFilename,
        tokenizerFilename: oldTokenizerFilename,
      );

      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: legacyRestored),
        isNull,
      );
      expect(
        prefs.getString(
          EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        ),
        isNull,
      );
    },
  );

  test('unknown provenance schema is cleared instead of adopted', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
      jsonEncode({'schemaVersion': 999}),
    );

    final unknown = EmbeddingModelSpec(
      name: 'custom',
      modelSource: ModelSource.file('/tmp/custom.tflite'),
      tokenizerSource: ModelSource.file('/tmp/custom.model'),
    );
    expect(await resolveActiveEmbeddingCatalogProfile(spec: unknown), isNull);
    expect(
      prefs.getString(EmbeddingCatalogPreferencesKeys.activeProfileProvenance),
      isNull,
    );
  });

  test(
    'a restored FileSource pair without a provenance record gets no profile',
    () async {
      // Nothing was persisted for this pair, so matching file names alone
      // must not label it: a FileSource path or name proves nothing about
      // the embedding space.
      const model = catalog.EmbeddingModel.embeddingGemma256;
      final restored = EmbeddingModelSpec(
        name: model.name,
        modelSource: ModelSource.file('/managed/${model.filename}'),
        tokenizerSource: ModelSource.file(
          '/managed/${model.tokenizerFilename}',
        ),
        modelFilename: model.filename,
        tokenizerFilename: model.tokenizerFilename,
      );
      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: restored),
        isNull,
      );
    },
  );

  test(
    'provenance for one catalog model never labels another model\'s files',
    () async {
      const model = catalog.EmbeddingModel.embeddingGemma256;
      const other = catalog.EmbeddingModel.gecko256;
      await persistVerifiedEmbeddingCatalogSelection(
        model,
        spec: _catalogSpec(model),
      );
      final prefs = await SharedPreferences.getInstance();

      final restoredOther = EmbeddingModelSpec(
        name: other.name,
        modelSource: ModelSource.file('/managed/${other.filename}'),
        tokenizerSource: ModelSource.file(
          '/managed/${other.tokenizerFilename}',
        ),
        modelFilename: other.filename,
        tokenizerFilename: other.tokenizerFilename,
      );
      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: restoredOther),
        isNull,
      );
      expect(
        prefs.getString(
          EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        ),
        isNull,
      );
    },
  );

  group('a self-contained (.litertlm) catalog entry', () {
    // No such entry ships yet (EmbeddingGemma 2 adds it); provenance must
    // already take one, or it would always resolve to null.
    const EmbeddingCatalogEntry entry = (
      profileId: 'eg2-test-profile-v1',
      sourceType: ModelSourceType.network,
      url: 'https://h/resolve/abc/eg2.litertlm',
      filename: 'eg2__rev-abc.litertlm',
      tokenizerUrl: null,
      tokenizerFilename: null,
    );
    EmbeddingModelSpec networkSpec() => EmbeddingModelSpec(
      name: 'eg2',
      modelSource: ModelSource.network(entry.url),
      modelFilename: entry.filename,
    );
    EmbeddingModelSpec restoredSpec([String? filename]) => EmbeddingModelSpec(
      name: 'eg2',
      modelSource: ModelSource.file('/managed/${filename ?? entry.filename}'),
      modelFilename: filename ?? entry.filename,
    );

    test('matches the spec installed from it, and no other', () {
      expect(
        embeddingCatalogProfileForSpec(networkSpec(), catalogEntries: [entry]),
        entry.profileId,
      );
      expect(
        embeddingCatalogProfileForSpec(
          EmbeddingModelSpec(
            name: 'eg2',
            modelSource: ModelSource.network('https://h/other.litertlm'),
            modelFilename: entry.filename,
          ),
          catalogEntries: [entry],
        ),
        isNull,
      );
    });

    test('restores its profile from the native FileSource', () async {
      expect(
        await resolveActiveEmbeddingCatalogProfile(
          spec: networkSpec(),
          catalogEntries: [entry],
        ),
        entry.profileId,
      );
      expect(
        await resolveActiveEmbeddingCatalogProfile(
          spec: restoredSpec(),
          catalogEntries: [entry],
        ),
        entry.profileId,
      );
      // Another bundle's file under the same record gets nothing.
      expect(
        await resolveActiveEmbeddingCatalogProfile(
          spec: restoredSpec('other__rev-abc.litertlm'),
          catalogEntries: [entry],
        ),
        isNull,
      );
    });

    test('a record with half a tokenizer is cleared, not adopted', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        jsonEncode({
          'schemaVersion': 1,
          'profileId': entry.profileId,
          'modelFilename': entry.filename,
          'modelSource': ModelSource.network(entry.url).encode(),
          'tokenizerFilename': 'stray.model',
        }),
      );
      expect(
        await resolveActiveEmbeddingCatalogProfile(
          spec: restoredSpec(),
          catalogEntries: [entry],
        ),
        isNull,
      );
      expect(
        prefs.getString(
          EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        ),
        isNull,
      );
    });
  });

  test('backend locations are isolated by backend and embedding profile', () {
    const first = 'embedding-profile-v1';
    const second = 'embedding-profile-v2';

    expect(
      RagBackend.sqlite.storageName(first),
      isNot(RagBackend.sqlite.storageName(second)),
    );
    expect(
      RagBackend.sqlite.storageName(first),
      isNot(RagBackend.qdrant.storageName(first)),
    );
  });

  test('failed provenance writes are reported', () async {
    const model = catalog.EmbeddingModel.embeddingGemma256;
    final storage = _FakeProvenanceStorage()..setResult = false;

    await expectLater(
      persistVerifiedEmbeddingCatalogSelection(
        model,
        spec: _catalogSpec(model),
        storage: storage,
      ),
      throwsStateError,
    );
  });

  test('active embedder switches invalidate an in-flight resolution', () async {
    const model = catalog.EmbeddingModel.embeddingGemma256;
    final first = _catalogSpec(model);
    final second = _catalogSpec(catalog.EmbeddingModel.gecko256);
    final storage = _FakeProvenanceStorage(blockSet: true);
    EmbeddingModelSpec? active = first;

    final resolving = resolveActiveEmbeddingCatalogProfile(
      storage: storage,
      activeSpecReader: () => active,
    );
    await storage.setStarted.future;
    active = second;
    storage.releaseSet();

    await expectLater(resolving, throwsStateError);
    expect(
      storage.getString(
        EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
      ),
      isNull,
    );
  });
}

/// The spec installing [model] from the catalog produces: two files, or the
/// one `.litertlm` bundle.
EmbeddingModelSpec _catalogSpec(catalog.EmbeddingModel model) {
  final tokenizerUrl = model.tokenizerUrl;
  return EmbeddingModelSpec(
    name: model.name,
    modelSource: _source(model.sourceType, model.url),
    tokenizerSource: tokenizerUrl == null
        ? null
        : _source(model.sourceType, tokenizerUrl),
    modelFilename: model.filename,
    tokenizerFilename: model.tokenizerFilename,
  );
}

ModelSource _source(ModelSourceType type, String location) => switch (type) {
  ModelSourceType.network => ModelSource.network(location),
  ModelSourceType.asset => ModelSource.asset(location),
  ModelSourceType.bundled => ModelSource.bundled(location),
};

class _FakeProvenanceStorage implements EmbeddingCatalogProvenanceStorage {
  _FakeProvenanceStorage({this.blockSet = false});

  final bool blockSet;
  bool setResult = true;
  bool removeResult = true;
  final values = <String, String>{};
  final setStarted = Completer<void>();
  Completer<void>? _setGate;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    if (!setStarted.isCompleted) setStarted.complete();
    if (blockSet) {
      _setGate ??= Completer<void>();
      await _setGate!.future;
    }
    if (setResult) values[key] = value;
    return setResult;
  }

  void releaseSet() => _setGate?.complete();

  @override
  Future<bool> remove(String key) async {
    if (removeResult) values.remove(key);
    return removeResult;
  }
}
