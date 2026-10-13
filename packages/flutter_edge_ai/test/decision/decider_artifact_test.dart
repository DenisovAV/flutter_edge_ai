// toArtifact / loadDecider: a stored decider answers exactly as the one it
// came from, through a JSON round trip, without embedding anything; another
// embedding space and malformed data are refused by name.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

final _table = <String, List<double>>{
  'a1': [1, 0, 0, 0.1],
  'a2': [0.9, 0.1, 0, 0],
  'a3': [0.95, 0, 0.1, 0],
  'b1': [0, 1, 0, 0.1],
  'b2': [0.1, 0.9, 0, 0],
  'b3': [0, 0.95, 0.1, 0],
  'c1': [0, 0, 1, 0.2],
  'c2': [0, 0.1, 0.9, 0],
  'c3': [0.1, 0, 0.95, 0],
  'q1': [0.7, 0.6, 0.1, 0],
  'q2': [0.1, 0.2, 0.9, 0.3],
  'q3': [-0.2, -0.1, 0, 1],
  'q4': [0.4, 0.4, 0.4, 0.4],
  'held a': [0.8, 0.2, 0.1, 0],
  'held b': [0.2, 0.8, 0, 0.1],
  'held c': [0.1, 0.1, 0.8, 0.1],
  'held c2': [0.4, 0, 0.6, 0],
  'description a': [1, 0.3, 0, 0],
};

FakeEmbedder _embedder({PreferredBackend? backend, int dimension = 4}) =>
    FakeEmbedder(dimension: dimension, table: _table, activeBackend: backend);

EmbeddingInput _t(String text) => EmbeddingInput.text(text);

List<DeciderOption> _options() => [
  DeciderOption(
    'a',
    description: 'description a',
    examples: [_t('a1'), _t('a2'), _t('a3')],
    metadata: {
      'tool': 'open_a',
      'args': [1, 2],
    },
  ),
  DeciderOption('b', examples: [_t('b1'), _t('b2'), _t('b3')]),
  DeciderOption(
    'c',
    examples: [
      _t('c1'),
      _t('c2'),
      _t('c3'),
      EmbeddingInput(
        text: 'c1',
        images: [
          Uint8List.fromList(const [1, 2]),
        ],
      ),
    ],
  ),
];

const _queries = ['q1', 'q2', 'q3', 'q4'];

Future<List<DeciderAnswer>> _answers(Decider decider) async => [
  for (final q in _queries) await decider.choose(DeciderInput(_t(q)), topK: 3),
];

/// A copy of [artifact] as it would come back from storage.
Map<String, Object?> _stored(Map<String, Object?> artifact) =>
    jsonDecode(jsonEncode(artifact)) as Map<String, Object?>;

/// The fake embeds media by its text part.
FakeEmbedder _mediaEmbedder() => FakeEmbedder(
  dimension: 4,
  table: _table,
  modalities: const {EmbeddingModality.text, EmbeddingModality.image},
);

void main() {
  final cases = <String, (DeciderMethod, DeciderCalibration)>{
    'centroid, cross-fit': (
      DeciderMethod.centroid,
      const DeciderCalibration.crossFit(),
    ),
    'centroid, none': (DeciderMethod.centroid, const DeciderCalibration.none()),
    'linear, minSimilarity': (
      DeciderMethod.linear,
      const DeciderCalibration.minSimilarity(0.6),
    ),
    'linear, labelled': (
      DeciderMethod.linear,
      DeciderCalibration.fromLabelled([
        (input: _t('held a'), optionId: 'a'),
        (input: _t('held b'), optionId: 'b'),
        (input: _t('held c'), optionId: 'c'),
        (input: _t('held c2'), optionId: 'a'),
      ], maxError: 0.5),
    ),
  };

  for (final MapEntry(key: name, value: (method, calibration))
      in cases.entries) {
    test('$name: the stored decider answers exactly as the original', () async {
      final original = await _mediaEmbedder().createDecider(
        options: _options(),
        method: method,
        calibration: calibration,
        embedderId: 'fake-v1',
      );
      final artifact = _stored(original.toArtifact());

      final embedder = _mediaEmbedder();
      final loaded = await embedder.loadDecider(
        artifact,
        embedderId: 'fake-v1',
      );
      expect(embedder.calls, isEmpty, reason: 'loading embeds nothing');

      final before = await _answers(original);
      final after = await _answers(loaded);
      for (var i = 0; i < _queries.length; i++) {
        expect(after[i].choice, before[i].choice);
        expect(after[i].abstainReason, before[i].abstainReason);
        expect(after[i].margin, before[i].margin);
        expect(after[i].confidence, before[i].confidence);
        expect(after[i].probabilities, before[i].probabilities);
        expect(
          [for (final r in after[i].ranked) (r.id, r.score, r.probability)],
          [for (final r in before[i].ranked) (r.id, r.score, r.probability)],
        );
        expect(after[i].provenance.threshold, before[i].provenance.threshold);
        expect(after[i].provenance.method, method);
        expect(after[i].provenance.calibration, calibration.kind);
        expect(after[i].provenance.spaceId, before[i].provenance.spaceId);
      }
      expect(
        loaded.capabilities.calibratedProbabilities,
        original.capabilities.calibratedProbabilities,
      );
      // A loaded decider stores the same artifact again.
      expect(loaded.toArtifact(), artifact);
    });
  }

  test('the artifact: versioned, options with texts, metadata and float32 '
      'vectors; media examples counted, not stored', () async {
    final decider = await _mediaEmbedder().createDecider(
      options: _options(),
      method: DeciderMethod.linear,
      embedderId: 'fake-v1',
    );
    final artifact = _stored(decider.toArtifact());
    expect(artifact['format'], 'flutter_edge_ai.decider');
    expect(artifact['version'], 1);
    expect(artifact['kind'], 'embedding');
    expect(artifact['method'], 'linear');
    expect(artifact['dimension'], 4);
    expect(artifact['taskType'], 'classification');
    expect(
      artifact['spaceId'],
      'model=fake-v1;dim=4;prefix=task: classification | query: ',
    );
    final calibration = artifact['calibration']! as Map;
    expect(calibration['kind'], 'crossFit');
    expect(calibration['keep'], 0.95);
    expect(calibration['threshold'], isA<double>());
    expect(calibration.containsKey('temperature'), isFalse);
    final options = (artifact['options']! as List).cast<Map>();
    expect(options[0]['id'], 'a');
    expect(options[0]['description'], 'description a');
    expect(options[0]['examples'], ['a1', 'a2', 'a3']);
    expect(options[0]['metadata'], {
      'tool': 'open_a',
      'args': [1, 2],
    });
    expect(base64.decode(options[0]['centroid'] as String), hasLength(16));
    expect(base64.decode(options[0]['weights'] as String), hasLength(16));
    expect(options[0]['bias'], isA<double>());
    expect(options[2]['examples'], ['c1', 'c2', 'c3']);
    expect(options[2]['mediaExamples'], 1);

    final loaded = await _mediaEmbedder().loadDecider(
      artifact,
      embedderId: 'fake-v1',
    );
    expect(loaded.options[0].metadata, {
      'tool': 'open_a',
      'args': [1, 2],
    });
    expect(loaded.options[2].examples.map((e) => e.text), ['c1', 'c2', 'c3']);
  });

  group('another embedding space is refused', () {
    Future<Map<String, Object?>> fitted() async => _stored(
      (await _embedder(backend: PreferredBackend.cpu).createDecider(
        options: _options().take(2).toList(),
        embedderId: 'eg2-270m',
      )).toArtifact(),
    );

    test('another model id', () async {
      await expectLater(
        _embedder(
          backend: PreferredBackend.cpu,
        ).loadDecider(await fitted(), embedderId: 'eg2-740m'),
        throwsA(
          isA<DeciderSpaceMismatchException>()
              .having((e) => e.expected, 'expected', contains('eg2-270m'))
              .having((e) => e.actual, 'actual', contains('eg2-740m')),
        ),
      );
    });

    test('the NPU instead of the CPU', () async {
      await expectLater(
        _embedder(
          backend: PreferredBackend.npu,
        ).loadDecider(await fitted(), embedderId: 'eg2-270m'),
        throwsA(
          isA<DeciderSpaceMismatchException>().having(
            (e) => e.actual,
            'actual',
            contains('backend=npu'),
          ),
        ),
      );
    });

    test('another dimension', () async {
      await expectLater(
        _embedder(
          backend: PreferredBackend.cpu,
          dimension: 3,
        ).loadDecider(await fitted(), embedderId: 'eg2-270m'),
        throwsA(isA<DeciderSpaceMismatchException>()),
      );
    });

    test('the same space loads; a closed embedder does not', () async {
      final embedder = _embedder(backend: PreferredBackend.cpu);
      final artifact = await fitted();
      await embedder.loadDecider(artifact, embedderId: 'eg2-270m');
      await embedder.close();
      await expectLater(
        embedder.loadDecider(artifact, embedderId: 'eg2-270m'),
        throwsA(isA<EmbedderClosedException>()),
      );
    });
  });

  group('malformed artifacts are a FormatException', () {
    late Map<String, Object?> good;
    setUp(() async {
      good = _stored(
        (await _embedder().createDecider(
          options: _options().take(2).toList(),
          method: DeciderMethod.linear,
          embedderId: 'm',
        )).toArtifact(),
      );
    });

    Map<String, Object?> edited(void Function(Map<String, Object?>) edit) {
      final copy = _stored(good);
      edit(copy);
      return copy;
    }

    Map<String, Object?> option0(Map<String, Object?> a) =>
        (a['options']! as List).first as Map<String, Object?>;

    final edits = <String, void Function(Map<String, Object?>)>{
      'another format': (a) => a['format'] = 'something.else',
      'a later version': (a) => a['version'] = 2,
      'another kind': (a) => a['kind'] = 'llm',
      'an unknown method': (a) => a['method'] = 'forest',
      'an unknown calibration': (a) =>
          (a['calibration']! as Map)['kind'] = 'magic',
      'a calibration without its threshold': (a) =>
          (a['calibration']! as Map).remove('threshold'),
      'no options': (a) => a['options'] = <Object?>[],
      'a vector that is not base64': (a) => option0(a)['centroid'] = '%%%',
      'a vector of the wrong length': (a) =>
          option0(a)['centroid'] = base64.encode(Uint8List(8)),
      'a non-finite vector value': (a) {
        final bytes = ByteData(16)..setFloat32(0, double.nan, Endian.little);
        option0(a)['centroid'] = base64.encode(bytes.buffer.asUint8List());
      },
      'a missing linear bias': (a) => option0(a).remove('bias'),
      'an option without an id': (a) => option0(a).remove('id'),
      'duplicate option ids': (a) =>
          ((a['options']! as List)[1] as Map)['id'] = 'a',
    };
    for (final MapEntry(key: name, value: edit) in edits.entries) {
      test(name, () async {
        await expectLater(
          _embedder().loadDecider(edited(edit), embedderId: 'm'),
          throwsA(isA<FormatException>()),
        );
      });
    }

    /// Unit centroid i of [option] scaled by [factor], base64 float32.
    String scaledCentroid(Map<String, Object?> option, double factor) {
      final bytes = base64.decode(option['centroid']! as String);
      final data = ByteData.sublistView(bytes);
      final out = ByteData(bytes.length);
      for (var j = 0; j < bytes.length ~/ 4; j++) {
        out.setFloat32(
          j * 4,
          data.getFloat32(j * 4, Endian.little) * factor,
          Endian.little,
        );
      }
      return base64.encode(out.buffer.asUint8List());
    }

    // Each refusal names what is wrong, so a corrupted store is debuggable.
    final named = <String, (void Function(Map<String, Object?>), String)>{
      'a threshold on a calibration that never abstains': (
        (a) {
          final calibration = a['calibration']! as Map<String, Object?>;
          calibration['kind'] = 'none';
          calibration['threshold'] = 0.5;
        },
        'threshold',
      ),
      'a labelled calibration without its temperature': (
        (a) => (a['calibration']! as Map)['kind'] = 'labelled',
        'temperature',
      ),
      'a temperature on a calibration that is not labelled': (
        (a) => (a['calibration']! as Map)['temperature'] = 0.5,
        'temperature',
      ),
      'a centroid that is not unit length': (
        (a) => option0(a)['centroid'] = scaledCentroid(option0(a), 1.5),
        'unit',
      ),
      'a linear decider with one option': (
        (a) => a['options'] = [option0(a)],
        'two options',
      ),
      'another task type': (
        (a) => a['taskType'] = 'retrievalQuery',
        'taskType',
      ),
      'a description that is not a string': (
        (a) => option0(a)['description'] = 3,
        'description',
      ),
      'an example that is not a string': (
        (a) => option0(a)['examples'] = [3],
        'examples',
      ),
      'metadata that is not a map': (
        (a) => option0(a)['metadata'] = [1],
        'metadata',
      ),
    };
    for (final MapEntry(key: name, value: (edit, field)) in named.entries) {
      test(name, () async {
        await expectLater(
          _embedder().loadDecider(edited(edit), embedderId: 'm'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(field),
            ),
          ),
        );
      });
    }

    test('a centroid within float32 rounding of unit length loads', () async {
      await _embedder().loadDecider(
        edited(
          (a) => option0(a)['centroid'] = scaledCentroid(option0(a), 1.0002),
        ),
        embedderId: 'm',
      );
    });
  });

  test(
    'metadata that is not JSON-encodable fails toArtifact by name',
    () async {
      final decider = await _embedder().createDecider(
        options: [
          DeciderOption('a', examples: [_t('a1'), _t('a2')]),
          DeciderOption(
            'b',
            examples: [_t('b1'), _t('b2')],
            metadata: {'callback': Object()},
          ),
        ],
        embedderId: 'm',
      );
      expect(
        decider.toArtifact,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('"b"'),
          ),
        ),
      );
    },
  );
}
