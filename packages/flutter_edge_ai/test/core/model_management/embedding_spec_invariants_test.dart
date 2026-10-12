// EmbeddingModelSpec's invariants (R5 §5.1) and the persisted identity's two
// schemas (§5.4): a .litertlm bundle is self-contained, everything else needs
// a tokenizer — on every construction path, identity restore included.

import 'dart:convert';

import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/model_management/active_embedding_identity.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_test/flutter_test.dart';

EmbeddingModelSpec _bundle({
  String url = 'https://h/embeddinggemma-2-text-270m.litertlm',
  String? modelFilename,
}) => EmbeddingModelSpec(
  name: 'eg2',
  modelSource: ModelSource.network(url),
  modelFilename: modelFilename,
);

EmbeddingModelSpec _pair({
  String model = 'https://h/embeddinggemma-300m_seq256.tflite',
  String tokenizer = 'https://h/sentencepiece.model',
}) => EmbeddingModelSpec(
  name: 'eg1',
  modelSource: ModelSource.network(model),
  tokenizerSource: ModelSource.network(tokenizer),
);

void main() {
  group('EmbeddingModelSpec invariants', () {
    test('a .litertlm bundle installs alone and is self-contained', () {
      final spec = _bundle();
      expect(spec.isSelfContained, isTrue);
      expect(spec.tokenizerSource, isNull);
      expect(spec.files.map((f) => f.filename), [
        'embeddinggemma-2-text-270m.litertlm',
      ]);
    });

    test('the suffix test is ASCII case-insensitive', () {
      expect(_bundle(url: 'https://h/MODEL.LITERTLM').isSelfContained, isTrue);
      expect(
        () => EmbeddingModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://h/Model.LiteRtLm'),
          tokenizerSource: ModelSource.network('https://h/t.model'),
        ),
        throwsArgumentError,
      );
    });

    test('an explicit .litertlm filename decides, not the URL', () {
      final spec = _bundle(
        url: 'https://h/resolve/abc/blob',
        modelFilename: 'eg2__rev-abc.litertlm',
      );
      expect(spec.isSelfContained, isTrue);
      expect(
        () => EmbeddingModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://h/x.litertlm'),
          modelFilename: 'x.tflite',
        ),
        throwsArgumentError,
        reason: 'the resolved name is a .tflite, which needs a tokenizer',
      );
    });

    test('a .litertlm bundle given a tokenizer is refused', () {
      expect(
        () => EmbeddingModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://h/x.litertlm'),
          tokenizerSource: ModelSource.network('https://h/t.model'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('carries its own tokenizer'),
          ),
        ),
      );
    });

    test('any other model without a tokenizer is refused', () {
      expect(
        () => EmbeddingModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://h/x.tflite'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('needs a tokenizer'),
          ),
        ),
      );
    });

    test('a tokenizer filename without a tokenizer source is refused', () {
      expect(
        () => EmbeddingModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://h/x.litertlm'),
          tokenizerFilename: 't.model',
        ),
        throwsArgumentError,
      );
    });

    test('two-file specs keep the collision check and their file order', () {
      final spec = _pair();
      expect(spec.isSelfContained, isFalse);
      expect(spec.files.map((f) => f.filename), [
        'embeddinggemma-300m_seq256.tflite',
        'embeddinggemma-300m_seq256__sentencepiece.model',
      ]);
      expect(
        () => EmbeddingModelSpec(
          name: 'x',
          modelSource: ModelSource.network('https://h/a.tflite'),
          tokenizerSource: ModelSource.network('https://h/t.model'),
          modelFilename: 'same.bin',
          tokenizerFilename: 'same.bin',
        ),
        throwsArgumentError,
      );
    });

    test('== and hashCode cover a null tokenizer', () {
      expect(_bundle(), _bundle());
      expect(_bundle().hashCode, _bundle().hashCode);
      expect(_bundle(), isNot(_pair()));
    });
  });

  group('ActiveEmbeddingIdentityRecord', () {
    test('a two-file spec is written as schema v1, byte for byte as in 2.1', () {
      final encoded = ActiveEmbeddingIdentityRecord.fromSpec(_pair()).encode();
      // Exactly what core 2.1.x wrote: a downgrade must still read it.
      expect(
        encoded,
        '{"schemaVersion":1,"active":true,"name":"eg1",'
        '"modelSource":${jsonEncode(ModelSource.network('https://h/embeddinggemma-300m_seq256.tflite').encode())},'
        '"tokenizerSource":${jsonEncode(ModelSource.network('https://h/sentencepiece.model').encode())},'
        '"modelFilename":"embeddinggemma-300m_seq256.tflite",'
        '"tokenizerFilename":"embeddinggemma-300m_seq256__sentencepiece.model",'
        '"modelFilenameExplicit":false,"tokenizerFilenameExplicit":false}',
      );
    });

    test(
      'a self-contained spec is written as schema v2, no tokenizer keys',
      () {
        final record = ActiveEmbeddingIdentityRecord.fromSpec(_bundle());
        final json = jsonDecode(record.encode()) as Map<String, dynamic>;
        expect(json, {
          'schemaVersion': 2,
          'active': true,
          'name': 'eg2',
          'modelSource': ModelSource.network(
            'https://h/embeddinggemma-2-text-270m.litertlm',
          ).encode(),
          'modelFilename': 'embeddinggemma-2-text-270m.litertlm',
          'modelFilenameExplicit': false,
        });
        expect(record.isSelfContained, isTrue);
      },
    );

    test('v2 round-trips to the same spec', () {
      for (final spec in [
        _bundle(),
        _bundle(url: 'https://h/blob', modelFilename: 'eg2__rev-1.litertlm'),
      ]) {
        final decoded = ActiveEmbeddingIdentityRecord.tryDecode(
          ActiveEmbeddingIdentityRecord.fromSpec(spec).encode(),
        );
        expect(decoded, isNotNull);
        expect(decoded!.toSpec(), spec);
      }
    });

    test('v1 still round-trips', () {
      final decoded = ActiveEmbeddingIdentityRecord.tryDecode(
        ActiveEmbeddingIdentityRecord.fromSpec(_pair()).encode(),
      );
      expect(decoded!.toSpec(), _pair());
      expect(decoded.isSelfContained, isFalse);
    });

    test('a clear is written as v1, so a downgrade still reads it', () {
      expect(
        const ActiveEmbeddingIdentityRecord.cleared().encode(),
        '{"schemaVersion":1,"active":false}',
      );
    });

    test('a 2.1 reader (schema 1 only) rejects v2 and restores nothing', () {
      // core 2.1.x's guard, verbatim: `value['schemaVersion'] !=
      // currentSchemaVersion` (1) → null.
      bool readBy21(String encoded) {
        final value = jsonDecode(encoded);
        return value is Map<String, dynamic> &&
            value['schemaVersion'] == 1 &&
            value['active'] is bool;
      }

      expect(
        readBy21(ActiveEmbeddingIdentityRecord.fromSpec(_bundle()).encode()),
        isFalse,
      );
      expect(
        readBy21(ActiveEmbeddingIdentityRecord.fromSpec(_pair()).encode()),
        isTrue,
      );
    });

    test('mixed records fail closed', () {
      // v2 naming a model that needs a tokenizer.
      expect(
        ActiveEmbeddingIdentityRecord.tryDecode(
          jsonEncode({
            'schemaVersion': 2,
            'active': true,
            'name': 'x',
            'modelSource': ModelSource.network('https://h/x.tflite').encode(),
            'modelFilename': 'x.tflite',
            'modelFilenameExplicit': false,
          }),
        ),
        isNull,
      );
      // v1 pairing a .litertlm bundle with a tokenizer.
      expect(
        ActiveEmbeddingIdentityRecord.tryDecode(
          jsonEncode({
            'schemaVersion': 1,
            'active': true,
            'name': 'x',
            'modelSource': ModelSource.network('https://h/x.litertlm').encode(),
            'tokenizerSource': ModelSource.network(
              'https://h/t.model',
            ).encode(),
            'modelFilename': 'x.litertlm',
            'tokenizerFilename': 'x__t.model',
            'modelFilenameExplicit': false,
            'tokenizerFilenameExplicit': false,
          }),
        ),
        isNull,
      );
      // An inactive v2 is never written — not even one carrying every field.
      expect(
        ActiveEmbeddingIdentityRecord.tryDecode(
          jsonEncode({
            'schemaVersion': 2,
            'active': false,
            'name': 'x',
            'modelSource': ModelSource.network('https://h/x.litertlm').encode(),
            'modelFilename': 'x.litertlm',
            'modelFilenameExplicit': false,
          }),
        ),
        isNull,
      );
      // A v2 whose filename does not resolve from its source.
      expect(
        ActiveEmbeddingIdentityRecord.tryDecode(
          jsonEncode({
            'schemaVersion': 2,
            'active': true,
            'name': 'x',
            'modelSource': ModelSource.network('https://h/x.litertlm').encode(),
            'modelFilename': 'other.litertlm',
            'modelFilenameExplicit': false,
          }),
        ),
        isNull,
      );
    });

    test('a native restore points a v2 record at the installed file', () {
      final record = ActiveEmbeddingIdentityRecord.tryDecode(
        ActiveEmbeddingIdentityRecord.fromSpec(_bundle()).encode(),
      )!;
      final restored = record.toSpec(
        runtimeModelSource: FileSource(
          '/data/embeddinggemma-2-text-270m.litertlm',
        ),
        runtimeTokenizerSource: FileSource('/ignored'),
      );
      expect(restored.isSelfContained, isTrue);
      expect(restored.files.single.filename, record.modelFilename);
    });
  });
}
