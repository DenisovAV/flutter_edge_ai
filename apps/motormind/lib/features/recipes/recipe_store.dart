import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Where recipe overrides live on the device. Tests inject a temp directory;
/// the app uses its documents folder.
final recipeDirProvider = FutureProvider<Directory>((ref) async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/recipes');
});

final recipeStoreProvider = AsyncNotifierProvider<RecipeStore, Map<String, ReadingRecipe>>(
  RecipeStore.new,
);

/// Reading recipes by site id. The shipped ones are assets; a repaired recipe
/// written to the device (by a person today, a help service later, DD-R27)
/// wins when its version is higher. A recipe that fails its self-check on a
/// real page is marked broken here and stays broken until a newer one passes.
class RecipeStore extends AsyncNotifier<Map<String, ReadingRecipe>> {
  static const shipped = ['echopark', 'cars'];

  @override
  Future<Map<String, ReadingRecipe>> build() async {
    final out = <String, ReadingRecipe>{};
    for (final id in shipped) {
      try {
        final text = await rootBundle.loadString('assets/recipes/$id.json');
        out[id] = ReadingRecipe.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
      } catch (e) {
        debugPrint('[motormind] recipe asset $id: $e');
      }
    }
    try {
      final dir = await ref.watch(recipeDirProvider.future);
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          final r = ReadingRecipe.fromJson(
            (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>(),
          );
          final current = out[r.siteId];
          if (current == null || r.version >= current.version) out[r.siteId] = r;
        }
      }
    } catch (e) {
      debugPrint('[motormind] recipe overrides: $e');
    }
    return out;
  }

  ReadingRecipe? forSite(String siteId) => state.value?[siteId];

  /// Record the outcome of a read on a real page. Verified recipes stay
  /// verified on a one-off failure (a slow page); a second failure in a row
  /// marks them broken.
  final Map<String, int> _failures = {};

  void recordCheck(String siteId, SelfCheck check) {
    final recipes = state.value;
    final r = recipes?[siteId];
    if (recipes == null || r == null) return;
    if (check.ok) {
      _failures[siteId] = 0;
      if (r.status != 'verified') {
        state = AsyncData({...recipes, siteId: r.copyWith(status: 'verified', note: null)});
      }
      return;
    }
    final n = (_failures[siteId] ?? 0) + 1;
    _failures[siteId] = n;
    if (r.status == 'unverified' || n >= 2) {
      state = AsyncData({
        ...recipes,
        siteId: r.copyWith(status: 'broken', note: check.problems.join('; ')),
      });
    }
  }

  /// Install a repaired recipe (DD-R27 drop-in). It is kept only if its
  /// version is not older than the current one.
  Future<void> install(ReadingRecipe r) async {
    final dir = await ref.read(recipeDirProvider.future);
    await dir.create(recursive: true);
    await File('${dir.path}/${r.siteId}.json').writeAsString(jsonEncode(r.toJson()));
    final recipes = state.value ?? {};
    final current = recipes[r.siteId];
    if (current == null || r.version >= current.version) {
      state = AsyncData({...recipes, r.siteId: r});
      _failures[r.siteId] = 0;
    }
  }
}
