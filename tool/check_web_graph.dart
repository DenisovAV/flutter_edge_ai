// Fails if a file a web build can reach imports dart:io, dart:ffi or
// dart:isolate.
//
// Why a static walk: the web compilers do not catch this. dart2js's
// libraries.json lists dart:io and dart:isolate (only dart:ffi is missing), and
// dart2wasm accepts all three, so a native import that leaks into the web graph
// compiles and fails only at RUNTIME, on the first call. The analyzer and the
// public-surface golden see the native branch of conditional directives, so
// they cannot see it either.
//
// What it walks: from every public library a web app can import — core's
// flutter_edge_ai.dart, engine.dart, engine_web.dart and genai.dart, every
// top-level library under lib/ of each workspace package that targets web, and
// each package's web plugin registrant (the pubspec's web `fileName`) —
// it follows import, export and part directives through the repository's own
// packages, taking the WEB branch of every conditional directive: the first
// `if (dart.library.X)` arm whose library exists on web (js_interop, html,
// ui_web, …), else the default arm (so `if (dart.library.io)` and
// `if (dart.library.ffi)` arms are never taken). Third-party packages are not
// followed; only repository files are checked.
//
// Native-only by contract, so not walked: the libraries in [_nativeOnly]. Each
// says so in its own doc comment; a web-reachable file importing one of them
// is still caught, because the walk follows it and finds its dart:io/ffi.
//
// It prints how many files it walked per entry point, so an empty or truncated
// walk is visible, and the import chain to every violation.
//
// Run from the repo root:  dart tool/check_web_graph.dart
// Exit 0: clean. 1: a web-reachable file imports a native library, or a
// directive could not be resolved. 2: nothing was walked.

import 'dart:io';

/// Libraries a web build must never reach.
const _banned = {'dart:io', 'dart:ffi', 'dart:isolate'};

/// `dart.library.X` is true on web for these X (dart2js and dart2wasm).
const _webLibraries = {
  'async',
  'collection',
  'convert',
  'core',
  'developer',
  'html',
  'indexed_db',
  'js',
  'js_interop',
  'js_interop_unsafe',
  'js_util',
  'math',
  'svg',
  'typed_data',
  'ui',
  'ui_web',
  'web_audio',
  'web_gl',
};

/// `dart.library.X` is false on web for these X.
const _nativeLibraries = {'cli', 'ffi', 'io', 'isolate', 'mirrors'};

/// Top-level libraries that are native-only by contract (each documents it),
/// as paths relative to the repo root.
const _nativeOnly = {
  'packages/flutter_edge_ai/lib/engine_io.dart':
      'dart:io / dart:ffi helpers for native-only leaves',
  'packages/flutter_edge_ai_embeddings/lib/embedding_tokenizer.dart':
      'native-only SentencePiece adapter',
  'packages/flutter_edge_ai_embeddings/lib/wordpiece_embedding_tokenizer.dart':
      'native-only WordPiece adapter',
  'packages/flutter_edge_ai_litertlm/lib/litert_bindings.dart':
      'native-only LiteRT FFI bindings',
};

void main() {
  final root = Directory.current;
  if (!File('${root.path}/pubspec.yaml').existsSync() ||
      !Directory('${root.path}/packages').existsSync()) {
    stderr.writeln('Run from the repo root (no packages/ here).');
    exit(2);
  }

  // Workspace packages: name -> lib/ directory, and whether they target web.
  final libDirs = <String, String>{};
  final entries = <String>[];
  final skipped = <String, String>{};
  final pkgDirs =
      Directory('packages').listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final dir in pkgDirs) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final text = pubspec.readAsStringSync();
    final name = RegExp(
      r'^name:\s*([A-Za-z0-9_]+)',
      multiLine: true,
    ).firstMatch(text)?.group(1);
    if (name == null) continue;
    libDirs[name] = '${dir.path}/lib';

    final platforms = _declaredPlatforms(text);
    if (platforms != null && !platforms.contains('web')) {
      skipped[dir.path] = 'declares no web platform (${platforms.join(', ')})';
      continue;
    }
    final libDir = Directory('${dir.path}/lib');
    if (!libDir.existsSync()) continue;
    final tops =
        libDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .map((f) => f.path)
            .toList()
          ..sort();
    for (final top in tops) {
      if (_nativeOnly.containsKey(top)) {
        skipped[top] = 'native-only by contract: ${_nativeOnly[top]}';
        continue;
      }
      entries.add(top);
    }
    // A web plugin's registrant entry (`flutter: plugin: platforms: web:
    // fileName:`) is compiled into every web app that depends on the package,
    // whether or not the app imports it.
    final webPlugin = _webPluginFile(text);
    if (webPlugin != null) entries.add('${dir.path}/lib/$webPlugin');
  }

  var violations = 0;
  var unresolved = 0;
  final everything = <String>{};
  print('==> Web import graph (web branch of every conditional directive)');
  for (final entry in entries) {
    final walk = _walk(entry, libDirs);
    everything.addAll(walk.visited);
    print('  ${walk.visited.length.toString().padLeft(4)} files  $entry');
    for (final v in walk.violations) {
      violations++;
      print('  FAIL  ${v.file} imports ${v.uri}');
      print('        via ${v.chain.join('\n            -> ')}');
    }
    for (final u in walk.unresolved) {
      unresolved++;
      print('  FAIL  $u');
    }
  }
  print('  Not walked:');
  skipped.forEach((path, why) => print('    $path — $why'));

  if (entries.isEmpty || everything.isEmpty) {
    print('==> check_web_graph: walked nothing — not a pass.');
    exit(2);
  }
  if (violations > 0 || unresolved > 0) {
    print(
      '==> check_web_graph: $violations native import(s) and $unresolved '
      'unresolved directive(s) in the web graph '
      '(${entries.length} entry points, ${everything.length} files).',
    );
    exit(1);
  }
  print(
    '==> check_web_graph: OK — ${entries.length} entry points, '
    '${everything.length} distinct repository files, no dart:io, dart:ffi or '
    'dart:isolate.',
  );
}

/// The `platforms:` keys of a pubspec, or null when it declares none.
List<String>? _declaredPlatforms(String pubspec) {
  final lines = pubspec.split('\n');
  final start = lines.indexWhere((l) => l.trimRight() == 'platforms:');
  if (start < 0) return null;
  final keys = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ')) break;
    final key = RegExp(r'^\s+([a-z]+):').firstMatch(line)?.group(1);
    if (key != null) keys.add(key);
  }
  return keys;
}

/// The `fileName:` of the pubspec's web plugin registration, if any.
String? _webPluginFile(String pubspec) {
  final lines = pubspec.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final web = RegExp(r'^(\s+)web:\s*$').firstMatch(lines[i]);
    if (web == null) continue;
    final indent = web.group(1)!.length;
    for (final line in lines.skip(i + 1)) {
      if (line.trim().isEmpty) continue;
      final lead = line.length - line.trimLeft().length;
      if (lead <= indent) break;
      final file = RegExp(r'^\s+fileName:\s*(\S+)').firstMatch(line);
      if (file != null) return file.group(1);
    }
  }
  return null;
}

class _Violation {
  _Violation(this.file, this.uri, this.chain);
  final String file;
  final String uri;
  final List<String> chain;
}

class _Walk {
  final visited = <String>{};
  final violations = <_Violation>[];
  final unresolved = <String>[];
}

_Walk _walk(String entry, Map<String, String> libDirs) {
  final walk = _Walk();
  final parent = <String, String?>{entry: null};
  final queue = <String>[entry];
  List<String> chainTo(String file) {
    final chain = <String>[];
    String? cur = file;
    while (cur != null) {
      chain.add(cur);
      cur = parent[cur];
    }
    return chain.reversed.toList();
  }

  while (queue.isNotEmpty) {
    final file = queue.removeAt(0);
    if (!walk.visited.add(file)) continue;
    final List<_Directive> directives;
    try {
      directives = _directives(File(file).readAsStringSync());
    } on FormatException catch (e) {
      walk.unresolved.add('$file: ${e.message}');
      continue;
    }
    for (final d in directives) {
      final String uri;
      try {
        uri = d.webUri();
      } on FormatException catch (e) {
        walk.unresolved.add('$file: ${e.message}');
        continue;
      }
      if (uri.startsWith('dart:')) {
        if (_banned.contains(uri)) {
          walk.violations.add(_Violation(file, uri, chainTo(file)));
        }
        continue;
      }
      final target = _resolve(file, uri, libDirs);
      if (target == null) continue; // a third-party package
      if (!File(target).existsSync()) {
        walk.unresolved.add('$file: $uri does not resolve to a file');
        continue;
      }
      if (!parent.containsKey(target)) {
        parent[target] = file;
        queue.add(target);
      }
    }
  }
  return walk;
}

/// The file [uri] names, or null when it is outside the repository.
String? _resolve(String from, String uri, Map<String, String> libDirs) {
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return null;
    final lib = libDirs[rest.substring(0, slash)];
    if (lib == null) return null;
    return _normalize('$lib/${rest.substring(slash + 1)}');
  }
  if (uri.contains(':')) return null;
  final dir = from.substring(0, from.lastIndexOf('/'));
  return _normalize('$dir/$uri');
}

String _normalize(String path) {
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part == '.' || part.isEmpty) continue;
    if (part == '..' && out.isNotEmpty && out.last != '..') {
      out.removeLast();
    } else {
      out.add(part);
    }
  }
  return out.join('/');
}

class _Directive {
  _Directive(this.uri, this.configurations);
  final String uri;

  /// (condition, uri) pairs, in source order.
  final List<(String, String)> configurations;

  /// The URI a web compiler selects.
  String webUri() {
    for (final (condition, uri) in configurations) {
      final m = RegExp(
        r'''^dart\.library\.([a-z_]+)(?:\s*==\s*(['"])true\2)?$''',
      ).firstMatch(condition);
      if (m == null) {
        throw FormatException('unsupported import condition "$condition"');
      }
      final library = m.group(1)!;
      if (_webLibraries.contains(library)) return uri;
      if (!_nativeLibraries.contains(library)) {
        throw FormatException(
          'unknown library in import condition "$condition" — add it to '
          '_webLibraries or _nativeLibraries in tool/check_web_graph.dart',
        );
      }
    }
    return uri;
  }
}

/// The import/export/part directives at the top of a Dart file.
List<_Directive> _directives(String source) {
  final text = _stripComments(source);
  final out = <_Directive>[];
  var i = 0;
  void skipSpace() {
    while (i < text.length && text[i].trim().isEmpty) {
      i++;
    }
  }

  while (true) {
    skipSpace();
    if (i >= text.length) break;
    if (text[i] == '@') {
      // An annotation (e.g. `@TestOn('vm')` before `library;`).
      i++;
      while (i < text.length && RegExp(r'[\w.]').hasMatch(text[i])) {
        i++;
      }
      skipSpace();
      if (i < text.length && text[i] == '(') i = _skipParens(text, i);
      continue;
    }
    final word = RegExp(r'[a-z]+').matchAsPrefix(text, i)?.group(0);
    if (word != 'library' &&
        word != 'import' &&
        word != 'export' &&
        word != 'part') {
      break;
    }
    final end = _statementEnd(text, i);
    final statement = text.substring(i, end);
    i = end + 1;
    if (word == 'library' || RegExp(r'^part\s+of\b').hasMatch(statement)) {
      continue;
    }
    final strings = RegExp(
      r'''(?:if\s*\(([^)]*)\)\s*)?(['"])([^'"]*)\2''',
    ).allMatches(statement).toList();
    if (strings.isEmpty) {
      throw FormatException('no URI in directive "$statement"');
    }
    final configurations = <(String, String)>[
      for (final m in strings.skip(1))
        if (m.group(1) != null) (m.group(1)!.trim(), m.group(3)!),
    ];
    out.add(_Directive(strings.first.group(3)!, configurations));
  }
  return out;
}

int _skipParens(String text, int open) {
  var depth = 0;
  var i = open;
  while (i < text.length) {
    final c = text[i];
    if (c == "'" || c == '"') {
      i = _skipString(text, i);
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
    i++;
  }
  return i;
}

/// Index of the `;` that ends the statement starting at [start].
int _statementEnd(String text, int start) {
  var i = start;
  while (i < text.length) {
    final c = text[i];
    if (c == "'" || c == '"') {
      i = _skipString(text, i);
      continue;
    }
    if (c == ';') return i;
    i++;
  }
  throw FormatException('unterminated directive at offset $start');
}

/// Index just past the string literal that starts at [i].
int _skipString(String text, int i) {
  final quote = text[i];
  final triple = text.startsWith(quote * 3, i);
  final delimiter = triple ? quote * 3 : quote;
  final raw = i > 0 && text[i - 1] == 'r';
  var j = i + delimiter.length;
  while (j < text.length) {
    if (!raw && text[j] == r'\') {
      j += 2;
      continue;
    }
    if (text.startsWith(delimiter, j)) return j + delimiter.length;
    if (!triple && text[j] == '\n') return j; // unterminated single-line
    j++;
  }
  return j;
}

/// [source] with `//` and `/* */` comments blanked out (strings kept).
String _stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      final end = _skipString(source, i);
      out.write(source.substring(i, end));
      i = end;
    } else if (source.startsWith('//', i)) {
      final nl = source.indexOf('\n', i);
      i = nl < 0 ? source.length : nl;
    } else if (source.startsWith('/*', i)) {
      var depth = 0;
      while (i < source.length) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
          if (depth == 0) break;
        } else {
          i++;
        }
      }
      out.write(' ');
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}
