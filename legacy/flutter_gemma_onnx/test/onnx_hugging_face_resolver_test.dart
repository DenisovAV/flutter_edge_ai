// OnnxHuggingFaceResolver resolves an ORT-GenAI model DIRECTORY from a Hugging
// Face repo: it lists the repo via the tree API, picks an execution-provider
// folder, and returns every file in it as a directory ResolvedHfModel. On web
// it returns a fileless (files == null) repo-id model. All HTTP is injected via
// the `fetch` seam — no network.

import 'dart:convert';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma_onnx/flutter_gemma_onnx.dart'
    show OnnxHuggingFaceResolver;
import 'package:flutter_test/flutter_test.dart';

/// A repo shipping a CPU variant (with external `.onnx_data`) and a CUDA
/// variant, each a complete ORT-GenAI directory, plus a stray root README.
final _tree = jsonEncode([
  {'type': 'directory', 'path': 'cpu_and_mobile'},
  {
    'type': 'file',
    'path': 'cpu_and_mobile/cpu-int4/genai_config.json',
    'size': 9,
  },
  {'type': 'file', 'path': 'cpu_and_mobile/cpu-int4/model.onnx', 'size': 9},
  {
    'type': 'file',
    'path': 'cpu_and_mobile/cpu-int4/model.onnx_data',
    'size': 9,
  },
  {'type': 'file', 'path': 'cpu_and_mobile/cpu-int4/tokenizer.json', 'size': 9},
  {'type': 'file', 'path': 'cuda/cuda-int4/genai_config.json', 'size': 9},
  {'type': 'file', 'path': 'cuda/cuda-int4/model.onnx', 'size': 9},
  {'type': 'file', 'path': 'cuda/cuda-int4/tokenizer.json', 'size': 9},
  {'type': 'file', 'path': 'README.md', 'size': 9},
]);

/// A fetch seam that returns [body] and records the URL + headers it saw.
({
  OnnxHuggingFaceResolver make,
  List<Uri> urls,
  List<Map<String, String>> headers,
})
_resolver(String body, {String? variant}) {
  final urls = <Uri>[];
  final headers = <Map<String, String>>[];
  final r = OnnxHuggingFaceResolver(
    variant: variant,
    fetch: (u, h) async {
      urls.add(u);
      headers.add(h);
      return body;
    },
  );
  return (make: r, urls: urls, headers: headers);
}

void main() {
  test(
    'canResolve claims exactly ModelFileType.onnx; name/priority stable',
    () {
      const r = OnnxHuggingFaceResolver();
      expect(r.name, 'onnx-huggingface');
      expect(r.priority, 0);
      expect(r.canResolve('o/r', fileType: ModelFileType.onnx), isTrue);
      for (final t in ModelFileType.values) {
        if (t == ModelFileType.onnx) continue;
        expect(r.canResolve('o/r', fileType: t), isFalse, reason: '$t');
      }
      expect(r.canResolve('o/r'), isFalse);
    },
  );

  test(
    'native: picks the CPU variant, returns every folder file by bare name '
    '(incl. external .onnx_data), and hits the tree API with the token',
    () async {
      final h = _resolver(_tree);
      final r = await h.make.resolve(
        'org/repo',
        platform: 'macos',
        token: 'hf_abc',
      );

      expect(r.files, isNotNull);
      expect(r.files!.map((f) => f.name).toSet(), {
        'genai_config.json',
        'model.onnx',
        'model.onnx_data',
        'tokenizer.json',
      });
      expect(r.file, 'genai_config.json');
      expect(r.directoryName, 'org__repo__cpu_and_mobile__cpu-int4');
      // Primary URL is revision-pinned into the chosen folder.
      expect(
        r.url,
        'https://huggingface.co/org/repo/resolve/main/cpu_and_mobile/cpu-int4/'
        'genai_config.json',
      );
      // Tree API called once, with the auth header.
      expect(
        h.urls.single.toString(),
        contains('/api/models/org/repo/tree/main'),
      );
      expect(h.headers.single['Authorization'], 'Bearer hf_abc');
    },
  );

  test(
    'native: a GPU request still auto-picks the CPU variant (GPU execution is '
    'not bundled) and notes the CPU EP',
    () async {
      final h = _resolver(_tree);
      final r = await h.make.resolve(
        'org/repo',
        platform: 'windows',
        preferredBackend: PreferredBackend.gpu,
      );
      // Auto pick is CPU-only in v1 — NOT the cuda folder, which the CPU runtime
      // could not load.
      expect(r.directoryName, 'org__repo__cpu_and_mobile__cpu-int4');
      expect(
        r.notes.any((n) => n.toLowerCase().contains('cpu execution-provider')),
        isTrue,
        reason: 'a release-visible note that the CPU EP variant was installed',
      );
    },
  );

  test(
    'native: a GPU-only repo (no CPU folder) picks the GPU variant and WARNS '
    'the CPU-only runtime may not load it — not a false "CPU variant" note',
    () async {
      final h = _resolver(
        jsonEncode([
          {'type': 'file', 'path': 'cuda/cuda-int4/genai_config.json'},
          {'type': 'file', 'path': 'cuda/cuda-int4/model.onnx'},
          {'type': 'file', 'path': 'cuda/cuda-int4/tokenizer.json'},
        ]),
      );
      final r = await h.make.resolve('org/repo', platform: 'macos');
      expect(r.directoryName, 'org__repo__cuda__cuda-int4');
      expect(
        r.notes.any((n) => n.toLowerCase().contains('may fail to load')),
        isTrue,
        reason: 'a GPU export must be flagged, not silently claimed as CPU',
      );
      expect(
        r.notes.any((n) => n.toLowerCase().contains('cpu execution-provider')),
        isFalse,
      );
    },
  );

  test(
    'native: pinning a GPU variant WARNS the CPU-only runtime may not load it',
    () async {
      final h = _resolver(_tree, variant: 'cuda/cuda-int4');
      final r = await h.make.resolve('org/repo', platform: 'macos');
      expect(r.directoryName, 'org__repo__cuda__cuda-int4');
      expect(
        r.notes.any((n) => n.toLowerCase().contains('may fail to load')),
        isTrue,
      );
      expect(
        r.notes.any((n) => n.toLowerCase().contains('cpu execution-provider')),
        isFalse,
      );
    },
  );

  test('native: a file entry with a non-string path is refused (not silently '
      'dropped, which would install an incomplete directory)', () async {
    final h = _resolver(
      jsonEncode([
        {'type': 'file', 'path': 'cpu/genai_config.json'},
        {'type': 'file', 'path': 'cpu/model.onnx'},
        {'type': 'file', 'path': 12345}, // malformed: path is not a string
      ]),
    );
    await expectLater(
      h.make.resolve('org/repo', platform: 'macos'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'native: >1000 tree entries is refused (undetectable truncation)',
    () async {
      final many = [
        for (var i = 0; i < 1000; i++) {'type': 'file', 'path': 'f$i.bin'},
      ];
      final h = _resolver(jsonEncode(many));
      await expectLater(
        h.make.resolve('org/repo', platform: 'macos'),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('native: a non-array tree response is a clear StateError', () async {
    final h = _resolver(jsonEncode({'error': 'rate limited'}));
    await expectLater(
      h.make.resolve('org/repo', platform: 'macos'),
      throwsA(isA<StateError>()),
    );
  });

  test('native: a folder with genai_config but no .onnx is refused', () async {
    final h = _resolver(
      jsonEncode([
        {'type': 'file', 'path': 'cpu/genai_config.json', 'size': 9},
        {'type': 'file', 'path': 'cpu/tokenizer.json', 'size': 9},
      ]),
    );
    await expectLater(
      h.make.resolve('org/repo', platform: 'macos'),
      throwsA(isA<StateError>()),
    );
  });

  test('native: an explicit variant overrides the backend heuristic', () async {
    final h = _resolver(_tree, variant: 'cuda/cuda-int4');
    final r = await h.make.resolve('org/repo', platform: 'macos');
    expect(r.directoryName, 'org__repo__cuda__cuda-int4');
  });

  test('native: an unknown variant is rejected', () async {
    final h = _resolver(_tree, variant: 'tpu/nope');
    await expectLater(
      h.make.resolve('org/repo', platform: 'macos'),
      throwsArgumentError,
    );
  });

  test('native: a repo without genai_config.json is rejected', () async {
    final h = _resolver(
      jsonEncode([
        {'type': 'file', 'path': 'model.onnx', 'size': 9},
        {'type': 'file', 'path': 'README.md', 'size': 9},
      ]),
    );
    await expectLater(
      h.make.resolve('org/repo', platform: 'macos'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'native: a root-level ORT-GenAI directory (no EP subfolders) resolves',
    () async {
      final h = _resolver(
        jsonEncode([
          {'type': 'file', 'path': 'genai_config.json', 'size': 9},
          {'type': 'file', 'path': 'model.onnx', 'size': 9},
          {'type': 'file', 'path': 'tokenizer.json', 'size': 9},
        ]),
      );
      final r = await h.make.resolve('org/repo', platform: 'linux');
      expect(r.directoryName, 'org__repo');
      expect(r.files!.map((f) => f.name).toSet(), {
        'genai_config.json',
        'model.onnx',
        'tokenizer.json',
      });
      expect(
        r.url,
        'https://huggingface.co/org/repo/resolve/main/genai_config.json',
      );
    },
  );

  test('web: fileless — files == null and the URL maps to the repo id, '
      'no tree fetch', () async {
    final h = _resolver(_tree);
    final r = await h.make.resolve('org/repo', platform: 'web');
    expect(r.files, isNull);
    expect(r.url, 'https://huggingface.co/org/repo');
    expect(r.fileType, ModelFileType.onnx);
    expect(h.urls, isEmpty, reason: 'web must not hit the tree API');
  });
}
