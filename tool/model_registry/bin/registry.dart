// The model registry tool. Run from tool/model_registry:
//
//   dart run bin/registry.dart check
//   dart run bin/registry.dart generate
//
// `check` validates model_registry/ (the repo root's) and that every
// generated file is what `generate` would write; it exits 1 on any problem.
// `generate` writes the generated files. See ../../model_registry/README.md.

import 'dart:io';

import 'package:model_registry/check.dart';
import 'package:model_registry/generate.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final command = args.isEmpty ? null : args.first;
  if (command != 'check' && command != 'generate') {
    stderr.writeln(
      'usage: dart run bin/registry.dart check|generate [--registry <dir>]',
    );
    exit(64);
  }
  final at = args.indexOf('--registry');
  final registry = Directory(
    at >= 0 && at + 1 < args.length ? args[at + 1] : _defaultRegistry(),
  );
  final repoRoot = p.dirname(p.absolute(registry.path));
  final result = checkRegistry(registry);
  for (final problem in result.problems) {
    stdout.writeln(problem);
  }
  if (result.problems.isNotEmpty) {
    stdout.writeln('${result.problems.length} problem(s)');
    exit(1);
  }

  var stale = 0;
  for (final file in generateAll(registry, result.entries)) {
    final target = File(p.join(repoRoot, file.path));
    final content = await formatDart(file.content);
    final current = target.existsSync() ? target.readAsStringSync() : null;
    if (current == content) continue;
    if (command == 'generate') {
      target
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      stdout.writeln('wrote ${file.path}');
    } else {
      stale++;
      stdout.writeln(
        '${file.path}: ${current == null ? 'missing' : 'stale'}; run '
        '`dart run bin/registry.dart generate`',
      );
    }
  }
  if (stale > 0) exit(1);
  stdout.writeln(
    '${result.entries.length} models, ${result.variantCount} variants: ok',
  );
}

/// model_registry/ at the repo root, two levels above this package.
String _defaultRegistry() {
  final package = p.dirname(p.dirname(p.fromUri(Platform.script)));
  return p.normalize(p.join(package, '..', '..', 'model_registry'));
}
