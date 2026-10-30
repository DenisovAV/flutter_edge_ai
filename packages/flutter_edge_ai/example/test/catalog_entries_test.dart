// The example's own settings for an entry that installs a model registry
// build must agree with what the registry records for that build.

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai_example/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

const _nativePlatforms = [
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
];

void main() {
  test('an entry installs registry builds of its own model type', () {
    var checked = 0;
    try {
      for (final platform in _nativePlatforms) {
        debugDefaultTargetPlatformOverride = platform;
        for (final model in Model.values) {
          final variant = model.catalogVariant;
          if (variant == null) continue;
          checked++;
          expect(
            model.modelType,
            variant.modelType,
            reason: '${model.name} on ${platform.name} installs ${variant.id}',
          );
        }
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(checked, greaterThan(0));
  });

  test('an NPU build is opened within the context it is compiled for', () {
    for (final model in Model.values) {
      final variant = model.catalogVariant;
      final compiled = variant?.requiredMaxTokens;
      if (compiled == null) continue;
      expect(
        model.maxTokens,
        lessThanOrEqualTo(compiled),
        reason: '${model.name}: ${variant!.id} is compiled for $compiled',
      );
    }
  });
}
