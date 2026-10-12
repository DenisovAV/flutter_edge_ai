import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:genkit/genkit.dart'
    show Genkit, SimulateConstrainedGenerationMiddleware;
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';
import 'package:genkit_flutter_edge_ai/src/converters/request_converter.dart';
import 'package:genkit_flutter_edge_ai/src/converters/tool_converter.dart';
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_embedder.dart';
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_model.dart';
import 'package:genkit_flutter_edge_ai/src/middleware/context_window.dart'
    show schemaInstructionsText;

import 'src/fake_runtime.dart';

/// What a Genkit model plugin owes its callers beyond generating text: config
/// validation before anything loads, tool refs and every tool response, media
/// typed and refused loudly, usage, the config schema in metadata, and errors
/// a hybrid router can act on.
void main() {
  late FakeRuntime runtime;
  late FakeInferenceChat chat;
  late FakeInferenceModel inferenceModel;

  setUp(() {
    chat = FakeInferenceChat();
    inferenceModel = FakeInferenceModel()..chatToReturn = chat;
    runtime = FakeRuntime(model: inferenceModel);
  });

  Model buildModel({bool supportsTools = true, bool supportsMedia = true}) =>
      createFlutterEdgeAiModel(
        name: 'flutter-edge-ai/test-model',
        modelType: gemma.ModelType.gemmaIt,
        fileType: gemma.ModelFileType.task,
        runtime: runtime,
        supportsTools: supportsTools,
        supportsMedia: supportsMedia,
      );

  ModelRequest request(
    List<Part> parts, {
    Map<String, dynamic>? config,
    List<ToolDefinition>? tools,
  }) => ModelRequest(
    messages: [Message(role: Role.user, content: parts)],
    config: config,
    tools: tools,
  );

  ModelRequest text(String value, {Map<String, dynamic>? config}) =>
      request([TextPart(text: value)], config: config);

  Matcher genkitError(StatusCode status, [Object? message]) => throwsA(
    isA<GenkitException>()
        .having((e) => e.status, 'status', status)
        .having((e) => e.message, 'message', message ?? anything),
  );

  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 1, 2]);
  final wav = Uint8List.fromList([
    ...ascii.encode('RIFF'),
    0,
    0,
    0,
    0,
    ...ascii.encode('WAVE'),
  ]);
  String dataUri(String type, Uint8List bytes) =>
      'data:$type;base64,${base64Encode(bytes)}';

  group('config', () {
    test('a maxOutputTokens larger than the context window is an '
        'INVALID_ARGUMENT', () async {
      await expectLater(
        buildModel()(
          text('hi', config: {'maxTokens': 512, 'maxOutputTokens': 600}),
        ),
        genkitError(StatusCode.invalidArgument, contains('maxOutputTokens')),
      );
      await buildModel()(
        text('hi', config: {'maxTokens': 512, 'maxOutputTokens': 512}),
      );
      expect(runtime.getActiveModelCallCount, 1);
    });

    test('a sampling value no engine takes is named in the error', () async {
      await expectLater(
        buildModel()(
          // The schema's minimum lets infinity through; the engines' check
          // does not.
          text('hi', config: {'temperature': double.infinity}),
        ),
        genkitError(StatusCode.invalidArgument, contains('temperature')),
      );
    });

    test('maxTokens below 1 is an INVALID_ARGUMENT before any load', () async {
      await expectLater(
        buildModel()(text('hi', config: {'maxTokens': 0})),
        genkitError(StatusCode.invalidArgument, contains('maxTokens')),
      );
      expect(runtime.getActiveModelCallCount, 0);
    });

    test('a maxTokens of the wrong type is an INVALID_ARGUMENT', () async {
      await expectLater(
        buildModel()(text('hi', config: {'maxTokens': 'big'})),
        genkitError(StatusCode.invalidArgument),
      );
    });

    test('a fractional maxTokens fails, an integral double passes', () async {
      await expectLater(
        buildModel()(text('hi', config: {'maxTokens': 0.9})),
        genkitError(StatusCode.invalidArgument),
      );
      await buildModel()(text('hi', config: {'maxTokens': 2048.0}));
      expect(inferenceModel.maxTokens, 2048);
    });

    test('toolChoice and backends outside the schema fail', () async {
      for (final config in [
        {'toolChoice': 'any'},
        {'preferredBackend': 'tpu'},
        {'preferredAudioBackend': 'GPU'},
      ]) {
        await expectLater(
          buildModel()(text('hi', config: config)),
          genkitError(StatusCode.invalidArgument),
          reason: '$config',
        );
      }
    });

    test('maxOutputTokens reaches createChat', () async {
      await buildModel()(text('hi', config: {'maxOutputTokens': 128}));
      expect(inferenceModel.lastMaxOutputTokens, 128);
    });

    test('the Model and its list() entry carry the options schema', () async {
      final model = buildModel();
      final schema = (model.metadata['model'] as Map)['customOptions'] as Map;
      expect((schema['properties'] as Map).keys, contains('maxOutputTokens'));

      final listed = await GenkitFlutterEdgeAiPlugin(
        models: [
          FlutterEdgeAiModelConfig(
            name: 'm',
            modelType: gemma.ModelType.gemmaIt,
            supportsTools: false,
            supportsMedia: false,
          ),
        ],
        embedders: [FlutterEdgeAiEmbedderConfig(name: 'e')],
        runtime: runtime,
      ).list();
      final modelInfo = listed.first.metadata['model'] as Map;
      expect(modelInfo['customOptions'], isNotNull);
      expect(modelInfo['supports'], containsPair('tools', false));
      expect(modelInfo['supports'], containsPair('media', false));
      final embedderInfo = listed.last.metadata['model'] as Map;
      expect(
        ((embedderInfo['customOptions'] as Map)['properties'] as Map).keys,
        contains('taskType'),
      );
    });
  });

  group('tools', () {
    test('every tool response of a turn reaches the chat, in order', () async {
      await buildModel()(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'weather?')],
            ),
            Message(
              role: Role.model,
              content: [
                ToolRequestPart(
                  toolRequest: ToolRequest(ref: 'call_0', name: 'a', input: {}),
                ),
                ToolRequestPart(
                  toolRequest: ToolRequest(ref: 'call_1', name: 'b', input: {}),
                ),
              ],
            ),
            Message(
              role: Role.tool,
              content: [
                ToolResponsePart(
                  toolResponse: ToolResponse(
                    ref: 'call_0',
                    name: 'a',
                    output: {'x': 1},
                  ),
                ),
                ToolResponsePart(
                  toolResponse: ToolResponse(
                    ref: 'call_1',
                    name: 'b',
                    output: 2,
                  ),
                ),
              ],
            ),
          ],
        ),
      );

      final responses = chat.receivedMessages
          .where((m) => m.type == gemma.MessageType.toolResponse)
          .toList();
      expect(responses.map((m) => m.toolName), ['a', 'b']);
      expect(jsonDecode(responses[0].text), {'x': 1});
      expect(jsonDecode(responses[1].text), {'result': 2});
    });

    test(
      'tool calls carry refs, the same in chunks and the response',
      () async {
        chat.streamingResponses = [
          const gemma.FunctionCallResponse(name: 'a', args: {}),
          const gemma.ParallelFunctionCallResponse(
            calls: [
              gemma.FunctionCallResponse(name: 'a', args: {'n': 2}),
              gemma.FunctionCallResponse(name: 'b', args: {}),
            ],
          ),
        ];
        final chunks = <ModelResponseChunk>[];
        final response = await buildModel()(text('go'), onChunk: chunks.add);

        List<String?> refs(List<Part> parts) => [
          for (final p in parts) p.toolRequest?.ref,
        ];
        expect(refs([for (final c in chunks) ...c.content]), [
          'call_0',
          'call_1',
          'call_2',
        ]);
        expect(refs(response.message!.content), ['call_0', 'call_1', 'call_2']);
      },
    );

    test(
      'a model configured without tools refuses them as UNIMPLEMENTED',
      () async {
        await expectLater(
          buildModel(supportsTools: false)(
            request(
              [TextPart(text: 'hi')],
              tools: [ToolDefinition(name: 't', description: 'd')],
            ),
          ),
          genkitError(StatusCode.unimplemented, contains('supportsTools')),
        );
      },
    );

    test(r'a $ref input schema is flattened; a recursive one fails', () {
      final tools = convertTools([
        ToolDefinition(
          name: 't',
          description: 'd',
          inputSchema: {
            r'$ref': r'#/$defs/Args',
            r'$defs': {
              'Args': {
                'type': 'object',
                'properties': {
                  'city': {'type': 'string'},
                },
              },
            },
          },
        ),
      ]);
      expect(tools.single.parameters, {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
        },
      });

      expect(
        () => convertTools([
          ToolDefinition(
            name: 'bad',
            description: 'd',
            inputSchema: {r'$ref': 1},
          ),
        ]),
        genkitError(StatusCode.invalidArgument, contains('bad')),
      );

      expect(
        () => convertTools([
          ToolDefinition(
            name: 'remote',
            description: 'd',
            inputSchema: {r'$ref': 'https://example.com/args.json'},
          ),
        ]),
        genkitError(StatusCode.invalidArgument, contains('remote')),
      );

      expect(
        () => convertTools([
          ToolDefinition(
            name: 'loop',
            description: 'd',
            inputSchema: {
              r'$ref': r'#/$defs/Node',
              r'$defs': {
                'Node': {
                  'type': 'object',
                  'properties': {
                    'next': {r'$ref': r'#/$defs/Node'},
                  },
                },
              },
            },
          ),
        ]),
        genkitError(StatusCode.invalidArgument, contains('loop')),
      );
    });
  });

  group('media', () {
    const images = {'supportImage': true};

    test('a media part without contentType is typed from its data URI, '
        'its extension-less bytes, or an octet-stream data URI', () async {
      for (final url in [
        dataUri('image/png', png),
        'data:;base64,${base64Encode(png)}',
        dataUri('application/octet-stream', png),
      ]) {
        chat.receivedMessages.clear();
        await buildModel()(
          request([
            TextPart(text: 'what is this?'),
            MediaPart(media: Media(url: url)),
          ], config: images),
        );
        expect(chat.receivedMessages.single.images, hasLength(1), reason: url);
      }
    });

    test('HEIF, M4A, MP3 and AAC bytes are recognised; mp4 video is not '
        'taken', () async {
      Uint8List ftyp(String brand) => Uint8List.fromList([
        0,
        0,
        0,
        24,
        ...ascii.encode('ftyp'),
        ...ascii.encode(brand),
        0,
        0,
      ]);
      final cases = <Uint8List, String>{
        ftyp('heic'): 'image',
        ftyp('M4A '): 'audio',
        Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00]): 'audio', // MP3 frame
        Uint8List.fromList([0xFF, 0xF1, 0x50, 0x80]): 'audio', // ADTS AAC
      };
      for (final MapEntry(key: bytes, value: kind) in cases.entries) {
        final messages = await convertMessages([
          Message(
            role: Role.user,
            content: [
              MediaPart(
                media: Media(url: 'data:;base64,${base64Encode(bytes)}'),
              ),
            ],
          ),
        ]);
        final message = messages.single;
        expect(
          kind == 'image' ? message.images : [?message.audioBytes],
          hasLength(1),
          reason: '$bytes',
        );
      }
      await expectLater(
        convertMessages([
          Message(
            role: Role.user,
            content: [
              MediaPart(
                media: Media(url: 'data:;base64,${base64Encode(ftyp('isom'))}'),
              ),
            ],
          ),
        ]),
        genkitError(StatusCode.invalidArgument, contains('video/mp4')),
      );
    });

    test('several images and an audio clip go together', () async {
      await buildModel()(
        request(
          [
            TextPart(text: 'compare'),
            MediaPart(media: Media(url: dataUri('image/png', png))),
            MediaPart(media: Media(url: dataUri('image/png', png))),
            MediaPart(media: Media(url: dataUri('audio/wav', wav))),
          ],
          config: {'supportImage': true, 'supportAudio': true},
        ),
      );
      final message = chat.receivedMessages.single;
      expect(message.images, hasLength(2));
      expect(message.audioBytes, isNotNull);
    });

    test('what the model cannot take is refused, not dropped', () async {
      final cases = <List<Part>>[
        [
          MediaPart(media: Media(url: dataUri('audio/wav', wav))),
          MediaPart(media: Media(url: dataUri('audio/wav', wav))),
        ],
        [MediaPart(media: Media(url: dataUri('video/mp4', png)))],
        [
          MediaPart(
            media: Media(url: 'data:;base64,${base64Encode([1, 2, 3])}'),
          ),
        ],
        [
          DataPart(data: {'k': 'v'}),
        ],
      ];
      for (final parts in cases) {
        await expectLater(
          buildModel()(
            request(
              [TextPart(text: 'x'), ...parts],
              config: {'supportImage': true, 'supportAudio': true},
            ),
          ),
          genkitError(StatusCode.invalidArgument),
          reason: '$parts',
        );
      }
      expect(runtime.getActiveModelCallCount, 0);
    });

    test('an image without supportImage, or on a text-only model, fails '
        'before the model loads', () async {
      final withImage = [
        TextPart(text: 'x'),
        MediaPart(media: Media(url: dataUri('image/png', png))),
      ];
      await expectLater(
        buildModel()(request(withImage)),
        genkitError(StatusCode.invalidArgument, contains('supportImage')),
      );
      await expectLater(
        buildModel(supportsMedia: false)(request(withImage, config: images)),
        genkitError(StatusCode.unimplemented, contains('supportsMedia')),
      );
      // The config alone asks a text-only model to load its vision encoder.
      await expectLater(
        buildModel(supportsMedia: false)(text('x', config: images)),
        genkitError(StatusCode.unimplemented, contains('supportImage')),
      );
      expect(runtime.getActiveModelCallCount, 0);
    });
  });

  group('messages', () {
    Future<List<gemma.Message>> convert(Message message) => convertMessages([
      message,
      Message(
        role: Role.user,
        content: [TextPart(text: 'q')],
      ),
    ]);

    test('a media type is read without case', () async {
      final messages = await convertMessages([
        Message(
          role: Role.user,
          content: [
            MediaPart(
              media: Media(
                url: dataUri('IMAGE/PNG', png),
                contentType: 'Image/PNG',
              ),
            ),
          ],
        ),
      ]);
      expect(messages.single.images, hasLength(1));
    });

    test('media outside a user message is refused, not dropped', () async {
      final media = MediaPart(media: Media(url: dataUri('image/png', png)));
      for (final role in [Role.model, Role.system]) {
        await expectLater(
          convert(
            Message(
              role: role,
              content: [
                TextPart(text: 't'),
                media,
              ],
            ),
          ),
          genkitError(StatusCode.invalidArgument, contains('media')),
          reason: role.value,
        );
      }
      await expectLater(
        convert(
          Message(
            role: Role.tool,
            content: [TextPart(text: 't')],
          ),
        ),
        genkitError(StatusCode.invalidArgument, contains('tool responses')),
      );
    });

    test('a system message with media fails even when the config sets the '
        'system instruction', () async {
      await expectLater(
        buildModel()(
          ModelRequest(
            messages: [
              Message(
                role: Role.system,
                content: [
                  MediaPart(media: Media(url: dataUri('image/png', png))),
                ],
              ),
              Message(
                role: Role.user,
                content: [TextPart(text: 'q')],
              ),
            ],
            config: {'systemInstruction': 'be brief'},
          ),
        ),
        genkitError(StatusCode.invalidArgument),
      );
    });

    test('an unknown role is refused', () async {
      await expectLater(
        convert(
          Message(
            role: const Role('critic'),
            content: [TextPart(text: 't')],
          ),
        ),
        genkitError(StatusCode.invalidArgument, contains('critic')),
      );
    });

    test("a model turn's reasoning is left out, not refused", () async {
      final messages = await convert(
        Message(
          role: Role.model,
          content: [
            ReasoningPart(reasoning: 'hmm'),
            TextPart(text: 'answer'),
          ],
        ),
      );
      expect(messages.first.text, 'answer');
    });

    test("a tool response's text content reaches the model", () async {
      final messages = await convert(
        Message(
          role: Role.tool,
          content: [
            ToolResponsePart(
              toolResponse: ToolResponse(
                name: 'search',
                output: {'hits': 2},
                content: [TextPart(text: 'first hit')],
              ),
            ),
          ],
        ),
      );
      final body = jsonDecode(messages.first.text) as Map<String, dynamic>;
      expect(body, containsPair('content', 'first hit'));
      expect(body, containsPair('hits', 2));
    });

    test("a tool response's media content is refused", () async {
      await expectLater(
        convert(
          Message(
            role: Role.tool,
            content: [
              ToolResponsePart(
                toolResponse: ToolResponse(
                  name: 'camera',
                  content: [
                    MediaPart(media: Media(url: dataUri('image/png', png))),
                  ],
                ),
              ),
            ],
          ),
        ),
        genkitError(StatusCode.invalidArgument, contains('camera')),
      );
    });
  });

  group('media downloads', () {
    List<Message> urlMessage(String url) => [
      Message(
        role: Role.user,
        content: [
          TextPart(text: 'x'),
          MediaPart(
            media: Media(url: url, contentType: 'image/png'),
          ),
        ],
      ),
    ];

    test('one deadline bounds the whole transfer, not each chunk', () async {
      // A byte every 20 ms never trips a per-chunk timer of 200 ms.
      final client = MockClient.streaming((request, _) async {
        final drip = Stream<List<int>>.periodic(
          const Duration(milliseconds: 20),
          (_) => [0],
        );
        return http.StreamedResponse(drip, 200);
      });
      final watch = Stopwatch()..start();
      await expectLater(
        convertMessages(
          urlMessage('https://media.example/img.png?token=secret'),
          httpClient: client,
          downloadTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<GenkitException>()
              .having((e) => e.status, 'status', StatusCode.deadlineExceeded)
              .having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('an extension-less URL is typed by the Content-Type it is served '
        'with', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'audio/mp4; codecs=mp4a'},
        ),
      );
      final messages = await convertMessages([
        Message(
          role: Role.user,
          content: [
            MediaPart(media: Media(url: 'https://media.example/clip?sig=1')),
          ],
        ),
      ], httpClient: client);
      expect(messages.single.audioBytes, isNotNull);
    });

    test('a rejected response releases its body', () async {
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final client = MockClient.streaming(
        (request, _) async => http.StreamedResponse(body.stream, 404),
      );
      await expectLater(
        convertMessages(
          urlMessage('https://media.example/missing.png'),
          httpClient: client,
        ),
        genkitError(StatusCode.invalidArgument, contains('404')),
      );
      expect(cancelled, isTrue);
    });

    test('a server error may pass and is UNAVAILABLE; a refusal is the '
        "URL's", () async {
      for (final (code, status) in [
        (503, StatusCode.unavailable),
        (429, StatusCode.unavailable),
        (403, StatusCode.invalidArgument),
      ]) {
        final client = MockClient((request) async => http.Response('', code));
        await expectLater(
          convertMessages(
            urlMessage('https://media.example/a.png'),
            httpClient: client,
          ),
          genkitError(status, contains('$code')),
          reason: '$code',
        );
      }
    });

    test('a cancel aborts a download in progress', () async {
      Future<void>? aborted;
      final client = MockClient.streaming((request, _) async {
        aborted = (request as http.Abortable).abortTrigger;
        return http.StreamedResponse(
          Stream<List<int>>.periodic(
            const Duration(milliseconds: 10),
            (_) => [0],
          ),
          200,
        );
      });
      final controller = CancellationController();
      final watch = Stopwatch()..start();
      final outcome = expectLater(
        convertMessages(
          urlMessage('https://media.example/slow.png'),
          httpClient: client,
          cancel: controller.token,
        ),
        throwsA(isA<CancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      controller.cancel();
      await outcome;
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      // The request itself is torn down, not only left unread.
      await aborted!.timeout(const Duration(seconds: 1));
    });

    test("one deadline covers all of a request's downloads", () async {
      final client = MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          Stream.fromFuture(
            Future.delayed(const Duration(milliseconds: 150), () => png),
          ),
          200,
        ),
      );
      // Each download fits in 250 ms; the two together do not.
      await expectLater(
        convertMessages(
          [
            ...urlMessage('https://media.example/a.png'),
            ...urlMessage('https://media.example/b.png'),
          ],
          httpClient: client,
          downloadTimeout: const Duration(milliseconds: 250),
        ),
        genkitError(StatusCode.deadlineExceeded),
      );
    });

    test('a network failure is UNAVAILABLE and says what failed', () async {
      final client = MockClient(
        (request) async =>
            throw http.ClientException('Connection reset', request.url),
      );
      await expectLater(
        convertMessages(
          urlMessage('https://media.example/a.png?token=secret'),
          httpClient: client,
        ),
        throwsA(
          isA<GenkitException>()
              .having((e) => e.status, 'status', StatusCode.unavailable)
              .having((e) => e.message, 'message', contains('Connection reset'))
              .having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
    });

    test(
      'a generic served Content-Type does not override the extension',
      () async {
        final client = MockClient(
          (request) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'text/plain'},
          ),
        );
        final messages = await convertMessages([
          Message(
            role: Role.user,
            content: [
              MediaPart(media: Media(url: 'https://media.example/clip.wav')),
            ],
          ),
        ], httpClient: client);
        expect(messages.single.audioBytes, isNotNull);
      },
    );

    test('an error inside the response handler fails the download, not the '
        'zone', () async {
      // A single-subscription body somebody already listens to: reading it
      // throws inside the handler.
      final body = StreamController<List<int>>();
      body.stream.listen(null);
      final client = MockClient.streaming(
        (request, _) async => http.StreamedResponse(body.stream, 200),
      );
      await expectLater(
        convertMessages(
          urlMessage('https://media.example/a.png'),
          httpClient: client,
          downloadTimeout: const Duration(seconds: 5),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a body over the size limit fails without reading it', () async {
      final client = MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          contentLength: kMaxMediaDownloadBytes + 1,
        ),
      );
      await expectLater(
        convertMessages(
          urlMessage('https://media.example/big.png'),
          httpClient: client,
        ),
        genkitError(StatusCode.invalidArgument, contains('limit')),
      );
    });
  });

  group('usage', () {
    test('token counts and speed come from the session', () async {
      chat.sessionMetrics = gemma.SessionMetrics(
        inputTokens: 12,
        outputTokens: 5,
        totalTokens: 17,
        timeToFirstTokenMs: 30,
        tokensPerSecond: 20,
      );
      final response = await buildModel()(text('hi'));
      expect(response.usage?.inputTokens, 12);
      expect(response.usage?.outputTokens, 5);
      expect(response.usage?.totalTokens, 17);
      expect(response.usage?.custom, {
        'timeToFirstTokenMs': 30,
        'tokensPerSecond': 20,
      });
    });

    test('usage comes from the session that generated, even when the chat '
        'replaces it afterwards', () async {
      chat
        ..sessionMetrics = gemma.SessionMetrics(
          inputTokens: 12,
          outputTokens: 5,
        )
        // A single-turn model's chat opens a fresh session once it answers.
        ..onGenerate = () => chat.sessionMetrics = gemma.SessionMetrics();
      final response = await buildModel()(text('hi'));
      expect(response.usage?.inputTokens, 12);
      expect(response.latencyMs, isNotNull);
    });

    test('an engine that reports zeros reports no usage', () async {
      chat.sessionMetrics = gemma.SessionMetrics();
      expect((await buildModel()(text('hi'))).usage, isNull);
    });

    test('images the request carried are counted', () async {
      final response = await buildModel()(
        request(
          [
            TextPart(text: 'x'),
            MediaPart(media: Media(url: dataUri('image/png', png))),
          ],
          config: {'supportImage': true},
        ),
      );
      expect(response.usage?.inputImages, 1);
    });
  });

  group('errors', () {
    test(
      'no model installed is UNAVAILABLE, so a router can fall back',
      () async {
        runtime
          ..activeModelName = null
          ..loadError = StateError('No active inference model set.');
        await expectLater(
          buildModel()(text('hi')),
          genkitError(StatusCode.unavailable, contains('No active inference')),
        );
      },
    );

    test('an installed model the app cannot run is FAILED_PRECONDITION, so '
        'a router does not hide it', () async {
      runtime.loadError = StateError('No inference engine can handle this');
      await expectLater(
        buildModel()(text('hi')),
        genkitError(StatusCode.failedPrecondition, contains('No inference')),
      );
    });

    test('an engine that cannot run here is UNAVAILABLE, so a router can '
        'fall back', () async {
      runtime.loadError = UnsupportedError('not on this platform');
      await expectLater(
        buildModel()(text('hi')),
        genkitError(StatusCode.unavailable, contains('not on this platform')),
      );
    });

    test('a RangeError is a bug, not an INVALID_ARGUMENT', () async {
      runtime.loadError = RangeError.index(3, [1, 2]);
      await expectLater(
        buildModel()(text('hi')),
        throwsA(
          isNot(
            isA<GenkitException>().having(
              (e) => e.status,
              'status',
              StatusCode.invalidArgument,
            ),
          ),
        ),
      );
    });

    test('a failure feeding the chat gets a status too', () async {
      chat.addQueryChunkError = StateError('session closed');
      await expectLater(
        buildModel()(text('hi')),
        genkitError(StatusCode.failedPrecondition, contains('session closed')),
      );
    });

    test(
      'a stop that fails after the generation failed is reported with it',
      () async {
        chat.stopError = StateError('stop failed');
        await expectLater(
          buildModel()(
            text('hi'),
            onChunk: (_) => throw StateError('sink closed'),
          ),
          throwsA(
            isA<GenkitException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('sink closed'),
                contains('stopping the generation also failed'),
              ),
            ),
          ),
        );
      },
    );
  });

  group('structured output', () {
    test(
      'a configured system instruction keeps the schema instructions',
      () async {
        final ai = Genkit(
          plugins: [
            GenkitFlutterEdgeAiPlugin(
              models: [
                FlutterEdgeAiModelConfig(
                  name: 'm',
                  modelType: gemma.ModelType.gemmaIt,
                ),
              ],
              runtime: runtime,
            ),
          ],
        );
        chat.blockingResponse = const gemma.TextResponse('{"taskType": "x"}');
        await ai.generate(
          model: flutterEdgeAi.model('m'),
          messages: [
            Message(
              role: Role.system,
              content: [TextPart(text: 'Be terse.')],
            ),
            Message(
              role: Role.user,
              content: [TextPart(text: 'Pick one.')],
            ),
          ],
          config: FlutterEdgeAiModelOptions(
            systemInstruction: 'You are a bot.',
          ),
          outputSchema: FlutterEdgeAiEmbedConfig.$schema,
        );
        final instruction = inferenceModel.lastSystemInstruction!;
        expect(instruction, startsWith('You are a bot.'));
        expect(instruction, contains('conform to the following schema'));
        expect(instruction, isNot(contains('Be terse.')));
      },
    );
  });

  group('trimContext', () {
    test(
      'a maxTokens that is not a positive integer is INVALID_ARGUMENT',
      () async {
        final middleware = ContextWindowMiddleware();
        for (final value in ['big', 0, 10.5, double.infinity]) {
          expect(
            () => middleware.model(
              text('hi', config: {'maxTokens': value}),
              ActionFnArg(),
              (r, c) async => ModelResponse(finishReason: FinishReason.stop),
            ),
            genkitError(StatusCode.invalidArgument),
            reason: '$value',
          );
        }
      },
    );

    test(
      'the reserved text is the text Genkit writes into the prompt',
      () async {
        final schema = FlutterEdgeAiEmbedConfig.$schema.jsonSchema();
        String? written;
        await SimulateConstrainedGenerationMiddleware().model(
          ModelRequest(
            messages: [
              Message(
                role: Role.user,
                content: [TextPart(text: 'x')],
              ),
            ],
            output: OutputConfig(constrained: true, schema: schema),
          ),
          ActionFnArg(),
          (r, c) async {
            written = r.messages.single.content.last.text;
            return ModelResponse(finishReason: FinishReason.stop);
          },
        );
        expect(schemaInstructionsText(schema), written);
      },
    );

    test(
      'a maxOutputTokens larger than the default reserve is held back',
      () async {
        final middleware = ContextWindowMiddleware();
        final old = Message(
          role: Role.user,
          content: [TextPart(text: 'a' * 400)], // ~100 tokens
        );
        final last = Message(
          role: Role.user,
          content: [TextPart(text: 'b' * 200)], // ~50 tokens
        );
        Future<int> keptWith(Map<String, dynamic> config) async {
          var kept = -1;
          await middleware.model(
            ModelRequest(messages: [old, last], config: config),
            ActionFnArg(),
            (r, c) async {
              kept = r.messages.length;
              return ModelResponse(finishReason: FinishReason.stop);
            },
          );
          return kept;
        }

        // 1024 - 256 leaves room for both; 1024 - 900 leaves room for the last.
        expect(await keptWith({'maxTokens': 1024}), 2);
        expect(await keptWith({'maxTokens': 1024, 'maxOutputTokens': 900}), 1);
        expect(await keptWith({'maxTokens': 1024, 'maxOutputTokens': 100}), 2);
      },
    );

    test('room is held for an output schema the model will add', () async {
      final schema = {
        'type': 'object',
        'properties': {
          for (var i = 0; i < 20; i++) 'field$i': {'type': 'string'},
        },
      };
      final schemaTokens = (schemaInstructionsText(schema).length / 4).ceil();
      // Both messages (~150 tokens) fit in what is left without the schema;
      // with it, only the last (~50) does.
      final middleware = ContextWindowMiddleware(
        maxInputTokens: schemaTokens + 120,
      );
      final old = Message(
        role: Role.user,
        content: [TextPart(text: 'a' * 400)], // ~100 tokens
      );
      final last = Message(
        role: Role.user,
        content: [TextPart(text: 'b' * 200)], // ~50 tokens
      );
      Future<int> keptWith(OutputConfig? output) async {
        var kept = -1;
        await middleware.model(
          ModelRequest(messages: [old, last], output: output),
          ActionFnArg(),
          (r, c) async {
            kept = r.messages.length;
            return ModelResponse(finishReason: FinishReason.stop);
          },
        );
        return kept;
      }

      expect(await keptWith(null), 2);
      expect(
        await keptWith(OutputConfig(constrained: true, schema: schema)),
        1,
      );
    });
  });

  group('embedder', () {
    EmbedRequest embedRequest(
      List<DocumentData> docs, [
      Map<String, dynamic>? options,
    ]) => EmbedRequest(input: docs, options: options);

    DocumentData doc(String value) =>
        DocumentData(content: [TextPart(text: value)]);

    test('texts are queries unless the options say documents', () async {
      final embedder = createFlutterEdgeAiEmbedder(
        name: 'flutter-edge-ai/e',
        runtime: runtime,
      );
      final model = runtime.embedderToReturn
        ..embeddingsToReturn = [
          [0.1],
        ];
      await embedder(embedRequest([doc('q')]));
      expect(model.lastTaskType, gemma.TaskType.retrievalQuery);
      await embedder(
        embedRequest([doc('d')], {'taskType': 'retrievalDocument'}),
      );
      expect(model.lastTaskType, gemma.TaskType.retrievalDocument);
    });

    test(
      'a document with no text part, or an unknown taskType, fails',
      () async {
        final embedder = createFlutterEdgeAiEmbedder(
          name: 'flutter-edge-ai/e',
          runtime: runtime,
        );
        await expectLater(
          embedder(
            embedRequest([
              DocumentData(
                content: [
                  MediaPart(media: Media(url: dataUri('image/png', png))),
                ],
              ),
            ]),
          ),
          genkitError(StatusCode.invalidArgument, contains('no text part')),
        );
        await expectLater(
          embedder(embedRequest([DocumentData(content: [])])),
          genkitError(StatusCode.invalidArgument, contains('no text part')),
        );
        // A text part with no text is no text either.
        await expectLater(
          embedder(embedRequest([doc('')])),
          genkitError(StatusCode.invalidArgument, contains('no text part')),
        );
        await expectLater(
          embedder(embedRequest([doc('d')], {'taskType': 'document'})),
          genkitError(StatusCode.invalidArgument),
        );
      },
    );

    test('no embedder installed is UNAVAILABLE', () async {
      runtime
        ..activeEmbedderName = null
        ..loadError = StateError('No active embedding model set.');
      await expectLater(
        createFlutterEdgeAiEmbedder(
          name: 'flutter-edge-ai/e',
          runtime: runtime,
        )(embedRequest([doc('q')])),
        genkitError(StatusCode.unavailable),
      );
    });

    test(
      'a closed embedder, or one no longer active, is loaded again',
      () async {
        runtime.embedderToReturn.embeddingsToReturn = [
          [0.1],
        ];
        final embedder = createFlutterEdgeAiEmbedder(
          name: 'flutter-edge-ai/e',
          runtime: runtime,
        );
        await embedder(embedRequest([doc('q')]));
        await embedder(embedRequest([doc('q')]));
        expect(runtime.getActiveEmbedderCallCount, 1);

        runtime.embedderToReturn.isClosed = true;
        runtime.embedderToReturn = FakeEmbeddingModel()
          ..embeddingsToReturn = [
            [0.2],
          ];
        final afterClose = await embedder(embedRequest([doc('q')]));
        expect(runtime.getActiveEmbedderCallCount, 2);
        expect(afterClose.embeddings.single.embedding, [0.2]);

        runtime.activeEmbedderName = 'another-embedder';
        await embedder(embedRequest([doc('q')]));
        expect(runtime.getActiveEmbedderCallCount, 3);
      },
    );

    test(
      'a vector count that does not match the documents is INTERNAL',
      () async {
        runtime.embedderToReturn.embeddingsToReturn = [
          [0.1],
        ];
        await expectLater(
          createFlutterEdgeAiEmbedder(
            name: 'flutter-edge-ai/e',
            runtime: runtime,
          )(embedRequest([doc('a'), doc('b')])),
          genkitError(StatusCode.internal, contains('1 vectors for 2')),
        );
      },
    );
  });

  group('model lifecycle', () {
    test('a model that core closed is loaded again', () async {
      final model = buildModel();
      await model(text('hi'));
      await model(text('hi'));
      expect(runtime.getActiveModelCallCount, 1);

      // What getActiveModel with other arguments does to the old handle.
      await inferenceModel.close();
      await model(text('hi'));
      expect(runtime.getActiveModelCallCount, 2);
    });

    test('a newly installed model is used, not the cached one', () async {
      final model = buildModel();
      await model(text('hi'));

      final next = FakeInferenceChat()
        ..blockingResponse = const gemma.TextResponse('from B');
      runtime
        ..activeModelName = 'model-b'
        ..modelToReturn = (FakeInferenceModel()..chatToReturn = next);
      final response = await model(text('hi'));
      expect(runtime.getActiveModelCallCount, 2);
      expect(response.text, 'from B');
    });

    test('every configured name shares one model and one queue', () async {
      final plugin = GenkitFlutterEdgeAiPlugin(
        models: [
          FlutterEdgeAiModelConfig(
            name: 'a',
            modelType: gemma.ModelType.gemmaIt,
          ),
          FlutterEdgeAiModelConfig(
            name: 'b',
            modelType: gemma.ModelType.gemmaIt,
          ),
        ],
        runtime: runtime,
      );
      final a = plugin.resolve(ActionType.model, 'a')! as Model;
      final b = plugin.resolve(ActionType.model, 'b')! as Model;
      chat.generationGate = Completer<void>();

      final first = a(text('one'));
      await pumpEventQueue();
      final second = b(text('two'));
      await pumpEventQueue();
      // b waits for a's generation instead of reaching the native model.
      expect(inferenceModel.createChatCallCount, 1);

      chat.generationGate!.complete();
      await Future.wait([first, second]);
      expect(inferenceModel.createChatCallCount, 2);
      expect(runtime.getActiveModelCallCount, 1);
    });

    test('a request that fails preparation fails at once and does not hold '
        'the queue', () async {
      final model = buildModel();
      chat.generationGate = Completer<void>();
      final first = model(text('one'));
      await pumpEventQueue();

      var rejected = false;
      final bad = model(text('two', config: {'maxTokens': 0})).then(
        (_) {},
        onError: (Object e) {
          rejected = true;
        },
      );
      final third = model(text('three'));
      await pumpEventQueue();
      // Rejected while the first request is still generating.
      expect(rejected, isTrue);

      chat.generationGate!.complete();
      await Future.wait([first, bad, third]);
      expect(inferenceModel.createChatCallCount, 2);
    });
  });
}
