# Shipped-manifest fixtures

Snapshots of every live `litertlm_manifest.json` the
[hf-to-litertlm](https://github.com/john-rocky/hf-to-litertlm) converter had
shipped as of 2026-10-05 — 71 repos, 112 variants — plus
`reference_goldens.json`: the file and backend the converter's own reference
reader (`readers/dart` in that repo) picks for every repo × platform × backend
hint over the same snapshot, 2272 rows, and a `_generator` row naming the
reader revision that produced them. The regression sweep in
`../shipped_manifests_regression_test.dart` runs the resolver over all of it,
offline, so the resolver is tested against the real published data rather
than synthetic shapes — and pinned to the reference selection on every
combination, not a hand-picked few.

`../live_hugging_face_test.dart` is the opt-in live leg: it checks this
snapshot against Hugging Face (drift, `sha256`/`size_bytes` against the repos'
LFS metadata, every resolvable URL, and a new repo shipping a manifest). When
it reports that the catalog moved, regenerate the snapshot from this
directory:

```sh
# 1. Every repo that ships a manifest, in the orgs the converter ships to.
repos=$(for author in litert-community mlboydaisuke; do
  curl -sL "https://huggingface.co/api/models?author=$author&limit=1000&full=true" |
    python3 -c 'import json, sys
for m in json.load(sys.stdin):
    if any(s.get("rfilename") == "litertlm_manifest.json" for s in m.get("siblings") or []):
        print(m["id"])'
done | sort)

# 2. Fetch each one (the file name is the repo id with "/" → "__").
rm -f *__*.json
for repo in $repos; do
  curl -sL "https://huggingface.co/$repo/resolve/main/litertlm_manifest.json" \
    -o "$(echo "$repo" | sed 's/\//__/').json"
done
```

Then regenerate `reference_goldens.json` with the reference reader. It is not a
dependency of this package, so use a throwaway Dart package that depends on it
at a pinned commit — an empty directory with this `pubspec.yaml`:

```yaml
name: dump_goldens
publish_to: none
environment:
  sdk: ^3.0.0
dependencies:
  litertlm_manifest:
    git:
      url: https://github.com/john-rocky/hf-to-litertlm
      path: readers/dart
      ref: 6a620c8aa767d9f33bcc3c04a7d11f6a1d0743b4 # litertlm_manifest 0.2.2
```

and this `dump.dart` next to it. Run `dart pub get`, then `dart run dump.dart
<this directory> > reference_goldens.json` from that package. To move to a
newer reader, change `ref:` to a later commit of that repo; the dump reads the
revision back from `pubspec.lock`, so the `_generator` row always names the
reader that ran, and a reader that did not come from a git revision writes
nothing:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:litertlm_manifest/litertlm_manifest.dart';

// Same keys and hints as the sweep test. A hint no variant lists falls back
// to the hint-free resolution — the resolver's hint-drop lane.
const platforms = [null, 'android', 'ios', 'macos', 'windows', 'linux', 'web', 'unknown'];
const hints = [null, 'cpu', 'gpu', 'npu'];

/// The reader revision pub resolved, read back from this package's
/// pubspec.lock — what actually ran, not what someone typed. A reader that
/// did not come from a git revision (a path dependency, say) has no
/// `resolved-ref`, and then no goldens are written.
Map<String, String> generator() {
  final lock = File('pubspec.lock').readAsStringSync();
  final entry = RegExp(r'^  litertlm_manifest:\n((?:    .*\n)+)', multiLine: true)
      .firstMatch(lock)?[1] ?? '';
  String? field(String name) =>
      RegExp('^ +$name: "?([^"\n]+)"?\$', multiLine: true).firstMatch(entry)?[1];
  final ref = field('resolved-ref');
  if (ref == null) {
    throw StateError('pubspec.lock has no git resolved-ref for litertlm_manifest');
  }
  return {
    'package': 'litertlm_manifest',
    'version': field('version')!,
    'url': field('url')!,
    'path': field('path')!,
    'ref': ref,
  };
}

void main(List<String> args) {
  final files = Directory(args.first)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json') && !f.path.endsWith('reference_goldens.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final out = <String, Map<String, String>>{'_generator': generator()};
  for (final f in files) {
    final manifest = LitertlmManifest.fromJson(f.readAsStringSync());
    for (final p in platforms) {
      for (final h in hints) {
        final r = manifest.resolve(platform: p, backend: h) ?? manifest.resolve(platform: p)!;
        out['${manifest.repo}|${p ?? "-"}|${h ?? "-"}'] = {'file': r.file, 'backend': r.backend};
      }
    }
  }
  // One row per line, so a regenerated file diffs row by row.
  final rows = out.entries.map((e) => '  ${jsonEncode(e.key)}: ${jsonEncode(e.value)}');
  stdout.writeln('{\n${rows.join(',\n')}\n}');
}
```

Finally update the dataset-shape counts and the per-repo expectations in the
sweep test — they are meant to fail when the distributions move, so that a
regenerated snapshot is looked at rather than waved through.
