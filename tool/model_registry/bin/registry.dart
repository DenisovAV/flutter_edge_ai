// The model registry tool. Run from tool/model_registry:
//
//   dart run bin/registry.dart check
//
// `check` validates model_registry/ (the repo root's) and exits 1 on any
// problem. See ../../model_registry/README.md.

import 'dart:io';

import 'package:model_registry/check.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  if (args.isEmpty || args.first != 'check') {
    stderr.writeln(
      'usage: dart run bin/registry.dart check [--registry <dir>]',
    );
    exit(64);
  }
  final at = args.indexOf('--registry');
  final dir = Directory(
    at >= 0 && at + 1 < args.length ? args[at + 1] : _defaultRegistry(),
  );
  final result = checkRegistry(dir);
  for (final problem in result.problems) {
    stdout.writeln(problem);
  }
  if (result.problems.isNotEmpty) {
    stdout.writeln('${result.problems.length} problem(s)');
    exit(1);
  }
  stdout.writeln(
    '${result.entries.length} models, ${result.variantCount} variants: ok',
  );
}

/// model_registry/ at the repo root, two levels above this package.
String _defaultRegistry() {
  final package = p.dirname(p.dirname(p.fromUri(Platform.script)));
  return p.normalize(p.join(package, '..', '..', 'model_registry'));
}
