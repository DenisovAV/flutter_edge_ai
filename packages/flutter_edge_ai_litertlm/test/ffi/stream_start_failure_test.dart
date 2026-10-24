import 'package:flutter_edge_ai_litertlm/src/ffi/stream_start_failure.dart';
import 'package:flutter_test/flutter_test.dart';

const _rollback =
    'INVALID_ARGUMENT: NPU executor\'s SetCurrentStep only supports rolling '
    'back one token at the end of decode';

void main() {
  test('names the status code and carries LiteRT-LM\'s reason', () {
    final message = streamStartFailureMessage(
      code: 3,
      nativeMessage: _rollback,
      npu: false,
      laterMessage: true,
    );

    expect(message, startsWith('Failed to start streaming (code: 3, '));
    expect(message, contains('INVALID_ARGUMENT)'));
    expect(message, contains('rolling back one token'));
    expect(message, isNot(contains('On the NPU')));
    expect(message, isNot(contains('nativeLogLevel')));
  });

  test('on the NPU, a later message points at the history', () {
    final message = streamStartFailureMessage(
      code: 3,
      nativeMessage: _rollback,
      npu: true,
      laterMessage: true,
    );

    expect(message, contains('On the NPU'));
    expect(message, contains('Start a new conversation'));
  });

  test('the first message on the NPU gets no history hint', () {
    final message = streamStartFailureMessage(
      code: 3,
      nativeMessage: 'something else',
      npu: true,
      laterMessage: false,
    );

    expect(message, isNot(contains('On the NPU')));
  });

  test('no reason from LiteRT-LM points at its log', () {
    for (final native in [null, '', '  ']) {
      final message = streamStartFailureMessage(
        code: 13,
        nativeMessage: native,
        npu: false,
        laterMessage: false,
      );

      expect(
        message,
        startsWith('Failed to start streaming (code: 13, INTERNAL).'),
      );
      expect(message, contains('nativeLogLevel: LiteRtLmLogLevel.verbose'));
    }
  });

  test('a code outside absl::StatusCode is shown bare', () {
    final message = streamStartFailureMessage(
      code: -1,
      nativeMessage: 'Failed to parse message JSON.',
      npu: false,
      laterMessage: false,
    );

    expect(
      message,
      'Failed to start streaming (code: -1): Failed to parse message JSON.',
    );
  });
}
