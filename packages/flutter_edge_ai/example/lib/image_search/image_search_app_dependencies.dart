import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:image_picker/image_picker.dart';

import '../gemma_bootstrap.dart';
import '../models/embedding_model.dart' show embedderBackendForProfile;
import '../rag_demo/rag_storage_location.dart';
import '../utils/installed_model_lookup.dart';
import 'image_search_controller.dart';
import 'photo_store.dart';

/// The app's wiring of the Image Search screen: the active embedder declared
/// with images, a SQLite image index (one location per image profile), photos
/// from `image_picker`, kept in the app's documents.
ImageSearchDependencies imageSearchAppDependencies() {
  final picker = ImagePicker();
  Future<PickedPhoto> read(XFile file) async =>
      (name: file.name, bytes: await file.readAsBytes());

  return ImageSearchDependencies(
    hasActiveEmbedder: FlutterEdgeAi.hasActiveEmbedder,
    textProfileId: activeEmbeddingProfileId,
    loadEmbedder: () async {
      // npu when the active model is a per-SoC NPU bundle.
      final profileId = await activeEmbeddingProfileId();
      return FlutterEdgeAi.getActiveEmbedder(
        supportImage: true,
        preferredBackend: profileId == null
            ? null
            : embedderBackendForProfile(profileId),
      );
    },
    ragEmbedder: (profileId) => FlutterEdgeAiActiveEmbedder(
      profileId: profileId,
      supportImage: true,
      preferredBackend: embedderBackendForProfile(profileId),
    ),
    openIndex: (embedder) async {
      final profile = await embedder.resolveProfile();
      // Its own location per image profile: one modality per location, and
      // never the text index of the same model.
      final location = await resolveRagStorageLocation(
        'image_search_sqlite_${profile.id}.db',
      );
      return exampleRag.open(
        spec: VectorStoreSpec(
          providerId: RagBackend.sqlite.providerId,
          location: location,
          documents: EmbeddingModality.image,
        ),
        embedder: embedder,
      );
    },
    photos: createPhotoStore(),
    // No resizing or re-encoding: the photo's own bytes reach the model, so a
    // container it cannot decode (HEIC, WebP) is refused, not silently
    // converted. The model scales every image to its vision budget itself.
    // Read one by one, when the screen gets to each photo: a batch of
    // full-size originals never sits in memory at once.
    pickPhotos: () async => [
      for (final file in await picker.pickMultiImage())
        (name: file.name, read: file.readAsBytes),
    ],
    pickQueryPhoto: () async {
      final file = await picker.pickImage(source: ImageSource.gallery);
      return file == null ? null : read(file);
    },
    loadSample: (key) async {
      final data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    },
  );
}
