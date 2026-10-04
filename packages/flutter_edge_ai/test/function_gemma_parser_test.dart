import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/function_call_parser.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_response.dart';

void main() {
  group('FunctionGemma Parser', () {
    test('parses function call with single parameter', () {
      const input =
          '<start_function_call>call:get_weather{location:<escape>San Francisco<escape>}<end_function_call>';

      final result = FunctionCallParser.parse(
        input,
        modelType: ModelType.functionGemma,
      );

      expect(result, isNotNull);
      expect(result!.name, equals('get_weather'));
      expect(result.args['location'], equals('San Francisco'));
    });

    test('parses function call with multiple parameters', () {
      const input =
          '<start_function_call>call:get_weather{location:<escape>Tokyo<escape>,unit:<escape>celsius<escape>}<end_function_call>';

      final result = FunctionCallParser.parse(
        input,
        modelType: ModelType.functionGemma,
      );

      expect(result, isNotNull);
      expect(result!.name, equals('get_weather'));
      expect(result.args['location'], equals('Tokyo'));
      expect(result.args['unit'], equals('celsius'));
    });

    test('returns null for invalid format', () {
      const input = 'Just some regular text';

      final result = FunctionCallParser.parse(
        input,
        modelType: ModelType.functionGemma,
      );

      expect(result, isNull);
    });

    test('isFunctionCallStart detects FunctionGemma format', () {
      expect(
        FunctionCallParser.isFunctionCallStart(
          '<start_function_call>call:test',
          modelType: ModelType.functionGemma,
        ),
        isTrue,
      );
    });

    test('isFunctionCallStart does not detect JSON for FunctionGemma', () {
      expect(
        FunctionCallParser.isFunctionCallStart(
          '{"name": "test"}',
          modelType: ModelType.functionGemma,
        ),
        isFalse,
      );
    });

    test('isFunctionCallComplete detects complete FunctionGemma call', () {
      const input = '<start_function_call>call:test{}<end_function_call>';

      expect(
        FunctionCallParser.isFunctionCallComplete(
          input,
          modelType: ModelType.functionGemma,
        ),
        isTrue,
      );
    });

    test('isFunctionCallComplete returns false for incomplete call', () {
      const input = '<start_function_call>call:test{param:<escape>value';

      expect(
        FunctionCallParser.isFunctionCallComplete(
          input,
          modelType: ModelType.functionGemma,
        ),
        isFalse,
      );
    });
  });

  // Argument shapes below are golden strings rendered by FunctionGemma's own
  // `chat_template.jinja` (its `format_argument` macro, `escape_keys=False`):
  //   string  -> <escape>value<escape>
  //   number  -> bare (42, -3, 1.5, -0.25)
  //   boolean -> bare (true / false)
  //   list    -> [item,item]  (items recurse: strings escaped, numbers bare)
  //   object  -> {key:value}  (bare keys, alphabetically sorted)
  //
  // The template ships with the model; an ungated copy lives at
  // huggingface.co/onnx-community/functiongemma-270m-it-ONNX. To re-derive these
  // strings after a template change, render `format_argument` with jinja2.
  group('FunctionGemma Parser - canonical argument types (#366)', () {
    FunctionCallResponse parseCall(String input) {
      final result = FunctionCallParser.parse(
        input,
        modelType: ModelType.functionGemma,
      );
      expect(result, isNotNull, reason: 'failed to parse: $input');
      return result!;
    }

    test('reporter repro: string + array + number in one call', () {
      final result = parseCall(
        '<start_function_call>call:move_files{destination:<escape>Documents<escape>,'
        'extensions:[<escape>pdf<escape>],min_size_mb:100}<end_function_call>',
      );

      expect(result.name, equals('move_files'));
      expect(result.args['destination'], equals('Documents'));
      expect(result.args['extensions'], equals(['pdf']));
      expect(result.args['min_size_mb'], equals(100));
      expect(result.args['min_size_mb'], isA<int>());
    });

    test('bare integer parses as int', () {
      final result = parseCall(
        '<start_function_call>call:f{count:42}<end_function_call>',
      );

      expect(result.args['count'], equals(42));
      expect(result.args['count'], isA<int>());
    });

    test('bare negative integer parses as int', () {
      final result = parseCall(
        '<start_function_call>call:f{older_than_days:-3}<end_function_call>',
      );

      expect(result.args['older_than_days'], equals(-3));
      expect(result.args['older_than_days'], isA<int>());
    });

    test('bare float parses as double', () {
      final result = parseCall(
        '<start_function_call>call:f{threshold:1.5}<end_function_call>',
      );

      expect(result.args['threshold'], equals(1.5));
      expect(result.args['threshold'], isA<double>());
    });

    test('bare negative float parses as double', () {
      final result = parseCall(
        '<start_function_call>call:f{delta:-0.25}<end_function_call>',
      );

      expect(result.args['delta'], equals(-0.25));
      expect(result.args['delta'], isA<double>());
    });

    test('bare booleans parse as bool', () {
      final result = parseCall(
        '<start_function_call>call:f{dry_run:false,recursive:true}<end_function_call>',
      );

      expect(result.args['recursive'], isTrue);
      expect(result.args['dry_run'], isFalse);
      expect(result.args['recursive'], isA<bool>());
    });

    test('array of escaped strings parses as List<String>', () {
      final result = parseCall(
        '<start_function_call>call:f{exts:[<escape>pdf<escape>,<escape>docx<escape>]}'
        '<end_function_call>',
      );

      expect(result.args['exts'], equals(['pdf', 'docx']));
    });

    test('array of bare numbers parses as List of num', () {
      final result = parseCall(
        '<start_function_call>call:f{sizes:[10,20,30]}<end_function_call>',
      );

      expect(result.args['sizes'], equals([10, 20, 30]));
    });

    test('empty array parses as empty List, not dropped', () {
      final result = parseCall(
        '<start_function_call>call:f{tags:[]}<end_function_call>',
      );

      expect(result.args.containsKey('tags'), isTrue);
      expect(result.args['tags'], isEmpty);
      expect(result.args['tags'], isA<List>());
    });

    test('nested object parses as Map with bare keys', () {
      final result = parseCall(
        '<start_function_call>call:f{nested:{a:<escape>x<escape>,b:2}}<end_function_call>',
      );

      expect(result.args['nested'], equals({'a': 'x', 'b': 2}));
    });

    test(
      'escaped string containing comma, brackets and digits stays intact',
      () {
        final result = parseCall(
          '<start_function_call>call:f{note:<escape>done, 100% [ok]<escape>}'
          '<end_function_call>',
        );

        expect(result.args['note'], equals('done, 100% [ok]'));
        expect(result.args.length, equals(1));
      },
    );

    test('mixed call keeps every argument with its own type', () {
      final result = parseCall(
        '<start_function_call>call:f{a:<escape>s<escape>,b:[1,2],c:true,d:-1.5,'
        'e:[<escape>x<escape>]}<end_function_call>',
      );

      expect(result.args['a'], equals('s'));
      expect(result.args['b'], equals([1, 2]));
      expect(result.args['c'], isTrue);
      expect(result.args['d'], equals(-1.5));
      expect(result.args['e'], equals(['x']));
    });

    test('unknown bare token is kept as String, never dropped', () {
      final result = parseCall(
        '<start_function_call>call:f{weird:100abc}<end_function_call>',
      );

      expect(result.args['weird'], equals('100abc'));
    });

    test('bare tokens the template cannot emit stay Strings', () {
      // Dart's int/double.tryParse accept forms Python's `str()` never renders.
      // Treating them as numbers would invent a type the model never meant.
      final result = parseCall(
        '<start_function_call>call:f{hex:0x1f,plus:+5,padded:007,'
        'inf:Infinity,nan:NaN}<end_function_call>',
      );

      expect(result.args['hex'], equals('0x1f'));
      expect(result.args['plus'], equals('+5'));
      expect(result.args['padded'], equals('007'));
      expect(result.args['inf'], equals('Infinity'));
      expect(result.args['nan'], equals('NaN'));
    });

    test('bare None parses as null, not the string "None"', () {
      // Python's None renders bare; a real "None" string arrives escaped, so
      // the mapping is collision-free.
      final result = parseCall(
        '<start_function_call>call:f{z:None,s:<escape>None<escape>,'
        'xs:[None,1]}<end_function_call>',
      );

      expect(result.args.containsKey('z'), isTrue);
      expect(result.args['z'], isNull);
      expect(result.args['s'], equals('None'));
      expect(result.args['xs'], equals([null, 1]));
    });

    test('a body it cannot fully consume yields no call at all', () {
      // The template does not escape `<escape>` inside a string value, so a
      // value containing the sentinel is ambiguous on the wire. Parsing what we
      // can and dropping the rest would fire the tool with corrupted arguments.
      final result = FunctionCallParser.parse(
        '<start_function_call>call:f{x:<escape>a<escape>b<escape>c<escape>,y:1}'
        '<end_function_call>',
        modelType: ModelType.functionGemma,
      );

      expect(result, isNull);
    });

    test('scientific notation still parses as double', () {
      // `str(1e-05)` in Python is `1e-05` — the template really can emit this.
      final result = parseCall(
        '<start_function_call>call:f{small:1e-05,big:1e+20}<end_function_call>',
      );

      expect(result.args['small'], equals(1e-05));
      expect(result.args['big'], equals(1e+20));
    });
  });

  // `chat.dart` appends one token at a time to a buffer and asks
  // `isFunctionCallComplete` after each one, parsing the first buffer that says
  // yes. So completeness must not fire on a `}` that closes a nested object or
  // sits inside an escaped string — everything after it is lost and leaks to the
  // user as plain text. These tests walk the buffer the way chat.dart does
  // instead of handing `parse()` a whole call, which is what hid the bug.
  group('FunctionGemma streaming completion gate (#366)', () {
    bool complete(String buffer) => FunctionCallParser.isFunctionCallComplete(
      buffer,
      modelType: ModelType.functionGemma,
    );

    /// The first prefix `chat.dart` would accept as a finished call.
    String? firstCompletePrefix(String full) {
      for (var i = 1; i <= full.length; i++) {
        final prefix = full.substring(0, i);
        if (complete(prefix)) return prefix;
      }
      return null;
    }

    test('does not complete on the brace closing a nested object', () {
      expect(complete('<start_function_call>call:f{a:{x:1}'), isFalse);
    });

    test('does not complete on a brace inside an escaped string', () {
      expect(
        complete('<start_function_call>call:f{msg:<escape>a}b<escape>'),
        isFalse,
      );
    });

    test('completes once the call\'s own brace closes', () {
      expect(complete('<start_function_call>call:f{a:{x:1},b:2}'), isTrue);
      expect(
        complete('<start_function_call>call:f{msg:<escape>a}b<escape>}'),
        isTrue,
      );
    });

    test('streamed nested-object call keeps every argument', () {
      const full =
          '<start_function_call>call:f{a:{x:1},b:2}<end_function_call>';
      final buffer = firstCompletePrefix(full);
      expect(buffer, isNotNull);

      final result = FunctionCallParser.parse(
        buffer!,
        modelType: ModelType.functionGemma,
      );
      expect(result, isNotNull);
      expect(result!.args['a'], equals({'x': 1}));
      expect(result.args['b'], equals(2), reason: 'b must not be dropped');
    });

    test('streamed call with a brace inside a string keeps every argument', () {
      const full =
          '<start_function_call>call:f{msg:<escape>a}b<escape>,x:1}<end_function_call>';
      final buffer = firstCompletePrefix(full);
      expect(buffer, isNotNull);

      final result = FunctionCallParser.parse(
        buffer!,
        modelType: ModelType.functionGemma,
      );
      expect(result, isNotNull);
      expect(result!.args['msg'], equals('a}b'));
      expect(result.args['x'], equals(1), reason: 'x must not be dropped');
    });

    test('parses a nested call whose end tag was cut off by a stop token', () {
      final result = FunctionCallParser.parse(
        '<start_function_call>call:f{a:{x:1},b:2}',
        modelType: ModelType.functionGemma,
      );

      expect(result, isNotNull);
      expect(
        result!.args,
        equals({
          'a': {'x': 1},
          'b': 2,
        }),
      );
    });
  });

  group('JSON Parser (existing models)', () {
    test('still works for gemmaIt', () {
      const input =
          '<tool_code>{"name": "get_weather", "parameters": {"location": "NYC"}}</tool_code>';

      final result = FunctionCallParser.parse(
        input,
        modelType: ModelType.gemmaIt,
      );

      expect(result, isNotNull);
      expect(result!.name, equals('get_weather'));
      expect(result.args['location'], equals('NYC'));
    });

    test('still works for null modelType (backward compatibility)', () {
      const input = '{"name": "test", "parameters": {"key": "value"}}';

      final result = FunctionCallParser.parse(input);

      expect(result, isNotNull);
      expect(result!.name, equals('test'));
      expect(result.args['key'], equals('value'));
    });

    test('isFunctionCallStart works for JSON models', () {
      expect(
        FunctionCallParser.isFunctionCallStart(
          '{"name": "test"}',
          modelType: ModelType.gemmaIt,
        ),
        isTrue,
      );
    });

    test('isFunctionCallComplete works for JSON models', () {
      const input = '{"name": "test", "parameters": {}}';

      expect(
        FunctionCallParser.isFunctionCallComplete(
          input,
          modelType: ModelType.gemmaIt,
        ),
        isTrue,
      );
    });
  });
}
