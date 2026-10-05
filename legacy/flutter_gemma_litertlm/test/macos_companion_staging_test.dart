@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #457 — the companion dylibs that `hook/build.dart` skips from Native Assets
/// on macOS (#247) are staged into the built `.app` by
/// `tool/stage_macos_companions.sh`, invoked from the app's `macos/Podfile`.
///
/// These tests build throwaway Mach-O stand-ins with `clang`, run the real
/// script over them, and assert the property that actually matters at runtime:
/// **every `@rpath` / `@executable_path` load command of `LiteRtLm` resolves to
/// a file inside the bundle.** They deliberately do NOT assert that the script
/// ran, or which commands it issued — #457 is a case where the staging step ran
/// to completion and silently changed nothing, so only the artifact can tell
/// the two apart.
void main() {
  final script = '${Directory.current.path}/tool/stage_macos_companions.sh';

  setUpAll(() {
    if (!File(script).existsSync()) {
      throw StateError('script under test not found: $script');
    }
  });

  test('a bundle whose companion was never staged is reported as broken', () {
    // Guards the guard: if `unresolvedLoads` returned empty for everything, the
    // two staging tests below would pass without proving anything.
    final f = _Fixture.create(companionRef: _Ref.rpathDylib);
    addTearDown(f.dispose);

    expect(
      f.unresolvedLoads(),
      isNotEmpty,
      reason: 'before staging, the companion is absent and must be reported',
    );
  });

  test('resolves the companion when LiteRtLm names it by @rpath', () {
    final f = _Fixture.create(companionRef: _Ref.rpathDylib);
    addTearDown(f.dispose);

    final r = f.runStagingScript(script);
    expect(r.exitCode, 0, reason: 'script failed:\n${r.stderr}');

    expect(
      f.unresolvedLoads(),
      isEmpty,
      reason:
          'LiteRtLm still references a file that is not in the bundle.\n'
          '${f.describe()}',
    );
  });

  test('fails the build when a companion cannot be staged at all', () {
    // The bundle would launch-crash; a build error beats a runtime dlopen
    // failure. Also proves the post-condition guard is reachable rather than
    // dead code that never fires.
    final f = _Fixture.create(companionRef: _Ref.rpathDylib);
    addTearDown(f.dispose);
    for (final e in Directory(f.sourceDir).listSync()) {
      e.deleteSync();
    }

    final r = f.runStagingScript(script);

    expect(
      r.exitCode,
      isNot(0),
      reason:
          'staging silently accepted a bundle '
          'whose companion is missing:\n${f.describe()}',
    );
    expect(r.stderr, contains('libGemmaModelConstraintProvider.dylib'));
  });

  test('resolves the companion when LiteRtLm names it by @executable_path', () {
    // The shape reported in #457: something relocated LiteRtLm before the
    // staging step, so the dependency is already
    // `@executable_path/../Frameworks/libGemmaModelConstraintProvider.dylib`
    // rather than the upstream `@rpath/lib….dylib`.
    final f = _Fixture.create(companionRef: _Ref.executablePathDylib);
    addTearDown(f.dispose);

    final r = f.runStagingScript(script);
    expect(r.exitCode, 0, reason: 'script failed:\n${r.stderr}');

    expect(
      f.unresolvedLoads(),
      isEmpty,
      reason:
          'LiteRtLm still references a file that is not in the bundle — '
          'this is the dlopen failure in #457.\n${f.describe()}',
    );
  });
}

/// How the throwaway `LiteRtLm` names its companion dependency.
enum _Ref {
  /// Upstream shape, straight out of the tarball.
  rpathDylib('@rpath/libGemmaModelConstraintProvider.dylib'),

  /// Post-relocation shape seen in #457.
  executablePathDylib(
    '@executable_path/../Frameworks/libGemmaModelConstraintProvider.dylib',
  );

  const _Ref(this.value);
  final String value;
}

/// A throwaway `.app` plus a source directory of companion dylibs, both built
/// with `clang` so `otool` / `install_name_tool` see real Mach-O files.
class _Fixture {
  _Fixture._(this.root, this.appDir, this.sourceDir);

  final Directory root;
  final String appDir;
  final String sourceDir;

  static const _companions = [
    'GemmaModelConstraintProvider',
    'LiteRtMetalAccelerator',
    'LiteRtTopKMetalSampler',
  ];

  String get frameworks => '$appDir/Contents/Frameworks';
  String get liteRtLm => '$frameworks/LiteRtLm.framework/Versions/A/LiteRtLm';

  static _Fixture create({required _Ref companionRef}) {
    final root = Directory.systemTemp.createTempSync('fg457_');
    final src = Directory('${root.path}/src')..createSync(recursive: true);
    final app = '${root.path}/Example.app';
    Directory('$app/Contents/MacOS').createSync(recursive: true);
    Directory(
      '$app/Contents/Frameworks/LiteRtLm.framework/Versions/A',
    ).createSync(recursive: true);

    final stub = File('${root.path}/stub.c')
      ..writeAsStringSync('int flutter_gemma_stub(void) { return 0; }\n');

    // The companions, as the Native Assets cache holds them.
    for (final base in _companions) {
      _run('clang', [
        '-dynamiclib',
        '-o',
        '${src.path}/lib$base.dylib',
        '-install_name',
        '@rpath/lib$base.dylib',
        stub.path,
      ]);
    }

    // LiteRtLm links GemmaModelConstraintProvider — a hard LC_LOAD_DYLIB, not a
    // dlopen, which is why a missing file fails at launch rather than at first
    // GPU use. headerpad matches how we build the real one.
    final lm =
        '$app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm';
    _run('clang', [
      '-dynamiclib',
      '-o',
      lm,
      '-install_name',
      '@rpath/LiteRtLm.framework/Versions/A/LiteRtLm',
      '-Wl,-headerpad_max_install_names',
      // The rpath the real binary carries, read off the cached
      // libLiteRtLm.dylib with `otool -l`. From Versions/A this walks up to
      // Contents/Frameworks, which is what makes the `@rpath/<X>.framework/…`
      // form resolve at runtime. A friendlier rpath here (say
      // `@executable_path/../Frameworks`) would let these tests pass through a
      // mechanism production does not have.
      '-Wl,-rpath,@loader_path/../../..',
      stub.path,
      '${src.path}/libGemmaModelConstraintProvider.dylib',
    ]);

    if (companionRef != _Ref.rpathDylib) {
      _run('install_name_tool', [
        '-change',
        _Ref.rpathDylib.value,
        companionRef.value,
        lm,
      ]);
    }

    return _Fixture._(root, app, src.path);
  }

  ProcessResult runStagingScript(String script) =>
      _run('sh', [script, frameworks, sourceDir], check: false);

  /// Load commands of [liteRtLm] that do not resolve to a file in the bundle.
  List<String> unresolvedLoads() {
    final selfId = (_run('otool', ['-D', liteRtLm]).stdout as String)
        .trim()
        .split('\n')
        .last
        .trim();

    final loads = (_run('otool', ['-L', liteRtLm]).stdout as String)
        .split('\n')
        .skip(1)
        .map((l) => l.trim().split(' ').first)
        .where((l) => l.startsWith('@') && l != selfId)
        .toSet();

    final rpaths = _rpathsOf(liteRtLm);
    return loads.where((l) => !_resolves(l, rpaths)).toList()..sort();
  }

  bool _resolves(String load, List<String> rpaths) {
    if (load.startsWith('@rpath/')) {
      final rest = load.substring('@rpath/'.length);
      return rpaths.any((r) => _resolves('$r/$rest', rpaths));
    }
    var path = load;
    if (path.startsWith('@executable_path/')) {
      path =
          '$appDir/Contents/MacOS/'
          '${path.substring('@executable_path/'.length)}';
    } else if (path.startsWith('@loader_path/')) {
      final dir = liteRtLm.substring(0, liteRtLm.lastIndexOf('/'));
      path = '$dir/${path.substring('@loader_path/'.length)}';
    } else if (path.startsWith('@')) {
      return false;
    }
    // `..` segments are resolved by the filesystem, as dyld resolves them.
    return File(path).existsSync();
  }

  List<String> _rpathsOf(String binary) {
    final out = (_run('otool', ['-l', binary]).stdout as String).split('\n');
    final paths = <String>[];
    for (var i = 0; i < out.length; i++) {
      if (!out[i].contains('LC_RPATH')) continue;
      final line = out
          .skip(i)
          .take(4)
          .firstWhere((l) => l.trim().startsWith('path '), orElse: () => '');
      if (line.isNotEmpty) paths.add(line.trim().split(' ')[1]);
    }
    return paths;
  }

  /// Human-readable state, so a failure says what the bundle looks like
  /// instead of only that a list was non-empty.
  String describe() {
    final dir = Directory(frameworks);
    final fw = dir.existsSync()
        ? dir.listSync().map((e) => '    ${e.path.split('/').last}').join('\n')
        : '    <no Frameworks/>';
    final loads = (_run('otool', ['-L', liteRtLm]).stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('@'))
        .map((l) => '    $l')
        .join('\n');
    return '  Frameworks/:\n$fw\n  LiteRtLm load commands:\n$loads';
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

ProcessResult _run(String exe, List<String> args, {bool check = true}) {
  final r = Process.runSync(exe, args);
  if (check && r.exitCode != 0) {
    throw ProcessException(exe, args, '${r.stdout}\n${r.stderr}', r.exitCode);
  }
  return r;
}
