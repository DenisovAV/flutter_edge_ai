import 'package:flutter/services.dart';

/// Lists the app's Flutter asset keys, so `TtsInstallationBuilder.fromAsset`
/// can report every missing file before installing any. Internal (not
/// exported); tests replace it.
Future<Set<String>> Function() listAppAssets = () async =>
    (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets().toSet();
