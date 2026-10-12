import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/widgets.dart';

export 'photo_store_stub.dart'
    if (dart.library.io) 'photo_store_io.dart'
    if (dart.library.js_interop) 'photo_store_web.dart'
    show createPhotoStore;

/// Where the Image Search screen keeps the photos it indexed.
///
/// A RAG image index stores a REFERENCE to each photo, never its bytes (the
/// `content` of a document); search results hand the reference back, and the
/// screen shows the photo through [imageFor]. A bundled sample is referenced
/// by its asset key (`asset:assets/eg2_vision/circle.png`); a picked photo is
/// copied into the app's documents directory (on the web, the origin private
/// file system), so the reference outlives the picker's temporary file and the
/// app's restarts, like the index itself.
abstract interface class PhotoStore {
  /// Keeps [bytes] (an encoded image picked as [name]) and returns the
  /// reference to store with its vector.
  Future<String> keep(Uint8List bytes, {required String name});

  /// The image a reference from [keep], or an asset reference, points to.
  ImageProvider imageFor(String reference);

  /// Deletes the photo [keep] stored under [reference] (one that could not
  /// be indexed). Asset references are left alone.
  Future<void> forget(String reference);

  /// Deletes every photo [keep] stored. Asset references need no cleanup.
  Future<void> forgetAll();
}

/// The reference of a bundled asset.
String assetPhotoReference(String assetKey) => 'asset:$assetKey';

/// The asset key in [reference], or null when it is not an asset reference.
String? assetKeyOf(String reference) => reference.startsWith('asset:')
    ? reference.substring('asset:'.length)
    : null;

/// A short name for a reference: the file name without the directory.
String photoLabel(String reference) => reference.split(RegExp(r'[/\\:]')).last;

/// What an asset reference shows; null for any other reference.
ImageProvider? assetImageFor(String reference) =>
    switch (assetKeyOf(reference)) {
      final key? => AssetImage(key),
      null => null,
    };
