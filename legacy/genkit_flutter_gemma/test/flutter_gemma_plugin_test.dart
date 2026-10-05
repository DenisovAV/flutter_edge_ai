import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/genkit_flutter_gemma.dart';

void main() {
  group('GenkitFlutterGemmaPlugin', () {
    late GenkitFlutterGemmaPlugin plugin;

    setUp(() {
      plugin = GenkitFlutterGemmaPlugin(
        models: [
          FlutterGemmaModelConfig(
            name: 'gemma-3-nano',
            modelType: gemma.ModelType.gemmaIt,
          ),
          FlutterGemmaModelConfig(
            name: 'deepseek-r1',
            modelType: gemma.ModelType.deepSeek,
            fileType: gemma.ModelFileType.binary,
          ),
        ],
      );
    });

    test('has correct plugin name', () {
      expect(plugin.name, 'flutter-gemma');
    });

    test('list() returns metadata for all configured models', () async {
      final metadata = await plugin.list();

      expect(metadata, hasLength(2));
      expect(metadata[0].name, 'flutter-gemma/gemma-3-nano');
      expect(metadata[0].actionType, ActionType.model);
      expect(metadata[1].name, 'flutter-gemma/deepseek-r1');

      final supports =
          (metadata[0].metadata['model'] as Map)['supports'] as Map;
      expect(supports['systemRole'], isTrue);
    });

    test('resolve() returns null for non-model action types', () {
      final result = plugin.resolve(ActionType.flow, 'gemma-3-nano');
      expect(result, isNull);
    });

    test('resolve() returns null for unknown model name', () {
      final result = plugin.resolve(ActionType.model, 'unknown');
      expect(result, isNull);
    });

    test('resolve() returns Model for known model', () {
      final result = plugin.resolve(ActionType.model, 'gemma-3-nano');
      expect(result, isNotNull);
      expect(result, isA<Model>());
    });

    test('resolve() caches actions and returns same instance', () {
      final first = plugin.resolve(ActionType.model, 'gemma-3-nano');
      final second = plugin.resolve(ActionType.model, 'gemma-3-nano');
      expect(identical(first, second), isTrue);
    });

    test('dispose() clears cached actions', () {
      final before = plugin.resolve(ActionType.model, 'gemma-3-nano');
      plugin.dispose();
      final after = plugin.resolve(ActionType.model, 'gemma-3-nano');
      expect(identical(before, after), isFalse);
    });
  });

  group('GenkitFlutterGemmaPlugin with embedders', () {
    late GenkitFlutterGemmaPlugin plugin;

    setUp(() {
      plugin = GenkitFlutterGemmaPlugin(
        models: [
          FlutterGemmaModelConfig(
            name: 'gemma-3-nano',
            modelType: gemma.ModelType.gemmaIt,
          ),
        ],
        embedders: [FlutterGemmaEmbedderConfig(name: 'embedding-gemma-300m')],
      );
    });

    test('list() includes both model and embedder metadata', () async {
      final metadata = await plugin.list();

      expect(metadata, hasLength(2));
      expect(metadata[0].actionType, ActionType.model);
      expect(metadata[1].actionType, ActionType.embedder);
      expect(metadata[1].name, 'flutter-gemma/embedding-gemma-300m');
    });

    test('resolve() returns Embedder for known embedder', () {
      final result = plugin.resolve(
        ActionType.embedder,
        'embedding-gemma-300m',
      );
      expect(result, isNotNull);
      expect(result, isA<Embedder>());
    });

    test('resolve() returns null for unknown embedder', () {
      final result = plugin.resolve(ActionType.embedder, 'unknown');
      expect(result, isNull);
    });
  });

  group('FlutterGemmaPluginHandle', () {
    test('model() returns ModelRef with correct name', () {
      final ref = flutterGemma.model('gemma-3-nano');
      expect(ref.name, 'flutter-gemma/gemma-3-nano');
    });

    test('embedder() returns EmbedderRef with correct name', () {
      final ref = flutterGemma.embedder('embedding-gemma-300m');
      expect(ref.name, 'flutter-gemma/embedding-gemma-300m');
    });
  });

  group('FlutterGemmaModelOptions', () {
    test('fromJson creates options correctly', () {
      final options = FlutterGemmaModelOptions.fromJson({
        'maxTokens': 2048,
        'temperature': 0.5,
        'topK': 40,
        'supportImage': true,
      });

      expect(options.maxTokens, 2048);
      expect(options.temperature, 0.5);
      expect(options.topK, 40);
      expect(options.supportImage, isTrue);
      expect(options.topP, isNull);
    });

    test('toJson only includes non-null fields', () {
      final options = FlutterGemmaModelOptions(
        maxTokens: 512,
        temperature: 0.9,
      );

      final json = options.toJson();

      expect(json, {'maxTokens': 512, 'temperature': 0.9});
      expect(json.containsKey('topK'), isFalse);
    });

    test('fromJson handles randomSeed and toolChoice', () {
      final options = FlutterGemmaModelOptions.fromJson({
        'randomSeed': 42,
        'toolChoice': 'required',
      });

      expect(options.randomSeed, 42);
      expect(options.toolChoice, 'required');
    });

    test('toJson includes randomSeed and toolChoice', () {
      final options = FlutterGemmaModelOptions(
        randomSeed: 42,
        toolChoice: 'none',
      );

      final json = options.toJson();

      expect(json['randomSeed'], 42);
      expect(json['toolChoice'], 'none');
    });

    test('fromJson parses systemInstruction', () {
      final options = FlutterGemmaModelOptions.fromJson({
        'systemInstruction': 'Be concise.',
      });

      expect(options.systemInstruction, 'Be concise.');
    });

    test('toJson includes systemInstruction when set, omits when null', () {
      final withInstruction = FlutterGemmaModelOptions(
        systemInstruction: 'Be helpful.',
      );
      final without = FlutterGemmaModelOptions();

      expect(withInstruction.toJson()['systemInstruction'], 'Be helpful.');
      expect(without.toJson().containsKey('systemInstruction'), isFalse);
    });

    test('schema provides JSON Schema', () {
      final schema = FlutterGemmaModelOptions.$schema.jsonSchema();

      expect(schema['type'], 'object');
      expect(schema['properties'], isA<Map>());
      expect((schema['properties'] as Map).containsKey('maxTokens'), isTrue);
    });
  });
}
