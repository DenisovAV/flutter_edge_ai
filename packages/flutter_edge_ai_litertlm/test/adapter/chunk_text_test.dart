// What a streamed litertlm_dart message shows core: its text (a thought in
// the channel markers core's parser reads) and the raw JSON chat.dart reads
// tool calls from.
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

void main() {
  test('a thought shows in the channel markers, text as it is', () {
    expect(
      liteRtLmChunkText(
        lm.Message(role: lm.Role.model, channels: const {'thought': 'hmm'}),
      ),
      '<|channel>thought\nhmm<channel|>',
    );
    expect(liteRtLmChunkText(lm.Message.model('Hi')), 'Hi');
    expect(
      liteRtLmChunkText(
        lm.Message(role: lm.Role.model, channels: const {'thought': ''}),
      ),
      '',
      reason: 'an empty thought is no thought',
    );
  });

  test(
    "a chunk of calls alone shows as its JSON, which core's parser reads",
    () {
      final chunk = lm.Message(
        role: lm.Role.model,
        toolCalls: [
          lm.ToolCall('get_weather', const {'city': 'Oslo'}),
        ],
      );
      final text = liteRtLmChunkText(chunk);
      expect(text, liteRtLmChunkJson(chunk));
      final calls = SdkResponseParser.extractToolCalls(
        liteRtLmChunkJson(lm.Message.model('a')) + liteRtLmChunkJson(chunk),
      );
      expect(calls.single.name, 'get_weather');
      expect(calls.single.args, {'city': 'Oslo'});
    },
  );
}
