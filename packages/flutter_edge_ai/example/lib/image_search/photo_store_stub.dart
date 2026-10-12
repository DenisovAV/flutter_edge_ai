import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/widgets.dart';

import 'photo_store.dart';

/// A platform with neither `dart:io` nor the web's file system: nothing is
/// kept. Bundled samples still show.
PhotoStore createPhotoStore() => const _NoPhotoStore();

final class _NoPhotoStore implements PhotoStore {
  const _NoPhotoStore();

  @override
  Future<String> keep(Uint8List bytes, {required String name}) => Future.error(
    UnsupportedError('Image search is not available on this platform.'),
  );

  @override
  ImageProvider imageFor(String reference) =>
      assetImageFor(reference) ??
      (throw UnsupportedError('No photo files on this platform: $reference'));

  @override
  Future<void> forget(String reference) async {}

  @override
  Future<void> forgetAll() async {}
}
