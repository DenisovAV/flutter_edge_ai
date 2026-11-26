// The page's module script lives in one place, `liteRtLmWebModuleShim`: every
// copy under packages/ (the READMEs, the example pages and the skills, all of
// which build against or ship with this workspace's litertlm_dart) is that
// text, so an app that copies any of them hands over the module the way this
// release reads it. Also the words a page without it is refused with.
//
// codelabs/ and website/ are not searched: the site deploys on merge, and its
// pages and the codelab apps build against the published
// flutter_edge_ai_litertlm, which reads window.Engine on @litert-lm/core
// 0.19.0 until the adapter release that moves to this runtime. They move to
// the new shim with that release, and join this search then.
//
// Run: dart test test/web/web_module_shim_test.dart
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/src/web/web_module_shim.dart';
import 'package:litertlm_dart/src/web/web_runtime_version.dart';
import 'package:test/test.dart';

/// The repository root, from this package.
const _root = '../..';

/// Where copies of the module script live.
const _searched = ['packages'];

/// Directories never searched: build output and dependencies.
const _skipped = {
  'build',
  '.dart_tool',
  'node_modules',
  '.git',
  'ios',
  'macos',
};

/// The first line of the loader, which every copy starts with.
const _loaderStart = 'window.litertLmReady = (async () => {';

/// Every non-Dart, non-Python file under [_searched] that carries the loader.
List<File> _carriers() {
  final found = <File>[];
  void walk(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entity is Directory) {
        if (!_skipped.contains(name)) walk(entity);
      } else if (entity is File &&
          (name.endsWith('.html') || name.endsWith('.md')) &&
          entity.readAsStringSync().contains(_loaderStart)) {
        found.add(entity);
      }
    }
  }

  for (final dir in _searched) {
    walk(Directory('$_root/$dir'));
  }
  return found;
}

/// [lines] without the indentation they share.
List<String> _dedent(List<String> lines) {
  final indent = lines
      .where((l) => l.trim().isNotEmpty)
      .map((l) => l.length - l.trimLeft().length)
      .reduce((a, b) => a < b ? a : b);
  return [for (final l in lines) l.length < indent ? l : l.substring(indent)];
}

void main() {
  test('the shim imports the pinned module and hands it over whole', () {
    expect(liteRtLmWebModuleShimLine, 'window.litertLm = m;');
    expect(
      liteRtLmWebModuleShim,
      '<script type="module">\n'
      'window.litertLmReady = (async () => {\n'
      "  const m = await import('$liteRtLmWebModuleUrl');\n"
      '  window.litertLm = m;\n'
      '  return m;\n'
      '})();\n'
      '</script>',
    );
  });

  final carriers = _carriers();

  test('the copies are found', () {
    // 2 example pages, 2 READMEs and a skill.
    expect(carriers.length, greaterThanOrEqualTo(5));
    final paths = carriers.map((f) => f.path).toList();
    for (final expected in [
      'packages/litertlm_dart/README.md',
      'packages/flutter_edge_ai_litertlm/README.md',
      'packages/flutter_edge_ai/example/web/index.html',
      'packages/genkit_flutter_edge_ai/example/web/index.html',
    ]) {
      expect(paths, contains('$_root/$expected'));
    }
  });

  final shim = liteRtLmWebModuleShim.split('\n');
  for (final file in carriers) {
    final path = file.path.substring(_root.length + 1);
    test('$path carries the module script word for word', () {
      final lines = file.readAsLinesSync();
      final starts = [
        for (var i = 0; i < lines.length; i++)
          if (lines[i].trim() == _loaderStart) i,
      ];
      expect(starts, hasLength(1), reason: 'one loader per file');
      final start = starts.single;
      // The `<script type="module">` line may sit at another indentation
      // than the script (an html page's convention): compare each part
      // without its own indentation.
      expect(lines[start - 1].trim(), shim.first);
      expect(
        _dedent(lines.sublist(start, start + shim.length - 2)),
        shim.sublist(1, shim.length - 1),
      );
      expect(lines[start + shim.length - 2].trim(), shim.last);
    });

    test('$path sets no global of the old shim', () {
      final text = file.readAsStringSync();
      expect(text, isNot(contains('window.Engine =')));
      expect(text, isNot(contains('window.EmbeddingEngine =')));
      expect(text, isNot(contains('LiteRtLmBackend')));
    });
  }

  group('the refusal of a page without window.litertLm', () {
    test('names the line and the module to import', () {
      final message = liteRtLmWebModuleMissingMessage(legacyPage: false);
      expect(message, contains('window.litertLm is not set'));
      expect(message, contains(liteRtLmWebModuleShimLine));
      expect(message, contains(liteRtLmWebModuleUrl));
      expect(message, isNot(contains('replace')));
    });

    test('on a page with the old shim, names the lines to replace', () {
      final message = liteRtLmWebModuleMissingMessage(legacyPage: true);
      expect(message, contains('window.Engine = m.Engine;'));
      expect(message, contains('window.EmbeddingEngine = m.EmbeddingEngine;'));
      expect(message, contains('with $liteRtLmWebModuleShimLine return m;'));
    });

    test('a value that is not an object is named', () {
      expect(
        liteRtLmWebModuleMissingMessage(
          legacyPage: true,
          what: 'a value of type string',
        ),
        startsWith('window.litertLm is a value of type string, not the '),
      );
    });

    test('a missing member is named with what is there', () {
      expect(
        liteRtLmWebModuleMemberMessage('Engine', 'a value of type undefined'),
        allOf(
          startsWith(
            'window.litertLm has no Engine (a value of type undefined): the '
            'page\'s @litert-lm/core is not one this release calls.',
          ),
          contains(liteRtLmWebModuleUrl),
        ),
      );
    });
  });
}
