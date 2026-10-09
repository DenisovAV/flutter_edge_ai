import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/log.dart';

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
/// written to the device (by a person today, a help service later) wins when
/// its version is at least the shipped one. A recipe that fails its
/// self-check on a real page is marked broken here and stays broken until a
/// newer one passes. [recordCheck] is called from inside a page read, so a
/// read can rebuild whatever watches this store.
class RecipeStore extends AsyncNotifier<Map<String, ReadingRecipe>> {
  /// Site ids with a recipe in `assets/recipes/`; must match the file names.
  static const List<String> shipped = ['echopark', 'cars'];

  /// A verified recipe survives one failed read (a slow page); the second
  /// failure in a row marks it broken.
  static const _failuresBeforeBroken = 2;

  /// Consecutive self-check failures per site; reset on a pass and on reload.
  final Map<String, int> _failures = {};

  @override
  Future<Map<String, ReadingRecipe>> build() async {
    _failures.clear();
    final out = <String, ReadingRecipe>{};
    for (final id in shipped) {
      try {
        final text = await rootBundle.loadString('assets/recipes/$id.json');
        out[id] = ReadingRecipe.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
      } on Exception catch (e) {
        logDev('recipe asset $id could not be loaded: $e');
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
    } on Exception catch (e) {
      logDev('recipe overrides could not be read: $e');
    }
    return out;
  }

  /// The recipe for [siteId]; null while the store is still loading or when
  /// no recipe covers the site. Readers that must not miss the recipe await
  /// the provider's future instead.
  ReadingRecipe? forSite(String siteId) => state.value?[siteId];

  /// Records the outcome of a read on a real page and moves the recipe's
  /// status accordingly (see [_failuresBeforeBroken]).
  void recordCheck(String siteId, SelfCheck check) {
    final recipes = state.value;
    final r = recipes?[siteId];
    if (recipes == null || r == null) return;
    if (check.ok) {
      _failures[siteId] = 0;
      if (r.status != RecipeStatus.verified) {
        state = AsyncData({...recipes, siteId: r.withStatus(RecipeStatus.verified, note: null)});
      }
      return;
    }
    final n = (_failures[siteId] ?? 0) + 1;
    _failures[siteId] = n;
    if (r.status == RecipeStatus.unverified || n >= _failuresBeforeBroken) {
      state = AsyncData({
        ...recipes,
        siteId: r.withStatus(RecipeStatus.broken, note: check.problems.join('; ')),
      });
    }
  }

  /// Installs a repaired recipe. An older version than the current one is
  /// refused and nothing is written, so a stale file cannot win on the next
  /// launch.
  Future<bool> install(ReadingRecipe r) async {
    final recipes = state.value ?? {};
    final current = recipes[r.siteId];
    if (current != null && r.version < current.version) return false;
    final dir = await ref.read(recipeDirProvider.future);
    await dir.create(recursive: true);
    await File('${dir.path}/${r.siteId}.json').writeAsString(jsonEncode(r.toJson()));
    state = AsyncData({...recipes, r.siteId: r});
    _failures[r.siteId] = 0;
    return true;
  }
}
