import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

/// An intent skill stand-in named after the action (mirrors how [AgentLoop]
/// builds the synthetic intent skill from the model's `intent` tool arg).
Skill _intentSkill(String intent) => Skill(
  name: intent,
  description: '',
  instructions: '',
  type: SkillType.intent,
);

void main() {
  group('NativeIntentExecutor — probe-chain', () {
    final executor = NativeIntentExecutor();

    test('canExecuteSkill is true for intent skills only', () {
      expect(executor.canExecuteSkill(_intentSkill('send_email')), isTrue);
      expect(
        executor.canExecuteSkill(
          const Skill(
            name: 'x',
            description: '',
            instructions: '',
            type: SkillType.js,
          ),
        ),
        isFalse,
      );
      expect(
        executor.canExecuteSkill(
          const Skill(
            name: 'x',
            description: '',
            instructions: '',
            type: SkillType.mcp,
          ),
        ),
        isFalse,
      );
    });

    test('canExecute (core String contract) bridges to the type', () {
      expect(executor.canExecute('intent'), isTrue);
      expect(executor.canExecute('mcp'), isFalse);
    });

    test('whitelist is exactly the six Gallery-parity intents', () {
      expect(executor.whitelistedIntents.toSet(), {
        'send_email',
        'send_text',
        'create_calendar_event',
        'read_calendar_events',
        'schedule_notification',
        'get_current_date_and_time',
      });
    });
  });

  group('NativeIntentExecutor — whitelist enforcement', () {
    test('unknown intent returns ErrorResult, never executes', () async {
      var ran = false;
      final executor = NativeIntentExecutor(
        handlers: {
          // Provide a handler only for a known intent; the unknown one has none.
          'send_email': (_) async {
            ran = true;
            return const TextResult('sent');
          },
        },
      );

      final result = await executor.handleIntent(
        'delete_all_files', // not whitelisted
        '{"path": "/"}',
      );

      expect(result, isA<ErrorResult>());
      expect((result as ErrorResult).message, contains('Unknown intent'));
      expect(ran, isFalse);
    });

    test(
      'execute() on a non-whitelisted intent skill returns ErrorResult',
      () async {
        final executor = NativeIntentExecutor();
        final result = await executor.execute(
          _intentSkill('format_disk'),
          '{}',
        );
        expect(result, isA<ErrorResult>());
        expect((result as ErrorResult).message, contains('Unknown intent'));
      },
    );

    test('isWhitelisted reflects the map', () {
      final executor = NativeIntentExecutor();
      expect(executor.isWhitelisted('send_email'), isTrue);
      expect(executor.isWhitelisted('rm_rf'), isFalse);
    });

    test('injected handler can extend the whitelist (host app seam)', () async {
      final executor = NativeIntentExecutor(
        handlers: {
          'read_calendar_events': (params) async =>
              TextResult('read for ${params['date']}'),
        },
      );
      final result = await executor.handleIntent(
        'read_calendar_events',
        '{"date": "2026-06-26"}',
      );
      expect(result, isA<TextResult>());
      expect((result as TextResult).text, 'read for 2026-06-26');
    });
  });

  group('NativeIntentExecutor — dispatch & data resolution', () {
    test('execute resolves the intent from the synthetic skill name', () async {
      String? seenDate;
      final executor = NativeIntentExecutor(
        handlers: {
          'read_calendar_events': (params) async {
            seenDate = params['date'] as String;
            return const TextResult('ok');
          },
        },
      );

      final result = await executor.execute(
        _intentSkill('read_calendar_events'),
        '{"date": "2026-01-02"}',
      );

      expect(result, isA<TextResult>());
      expect(seenDate, '2026-01-02');
    });

    test(
      'execute falls back to an inline {intent, parameters} payload',
      () async {
        // The synthetic skill is NOT named after a whitelisted intent here; the
        // intent + parameters are carried inside the data payload instead.
        String? seenEmail;
        final executor = NativeIntentExecutor(
          handlers: {
            'send_email': (params) async {
              seenEmail = params['extra_email'] as String;
              return const TextResult('queued');
            },
          },
        );

        final result = await executor.execute(
          _intentSkill('runIntent'), // generic, not whitelisted
          '{"intent": "send_email", '
          '"parameters": {"extra_email": "a@b.com", '
          '"extra_subject": "hi", "extra_text": "yo"}}',
        );

        expect(result, isA<TextResult>());
        expect(seenEmail, 'a@b.com');
      },
    );

    test(
      'inline parameters string that is not valid JSON returns ErrorResult',
      () async {
        // Regression M5: a malformed inner "parameters" string must surface an
        // error, not silently validate the outer wrapper map.
        var handlerRan = false;
        final executor = NativeIntentExecutor(
          handlers: {
            'send_email': (_) async {
              handlerRan = true;
              return const TextResult('queued');
            },
          },
        );

        final result = await executor.execute(
          _intentSkill('runIntent'),
          '{"intent": "send_email", "parameters": "{not valid json"}',
        );

        expect(result, isA<ErrorResult>());
        expect((result as ErrorResult).message, contains('not valid JSON'));
        expect(handlerRan, isFalse);
      },
    );

    test('non-JSON-object data returns ErrorResult', () async {
      final executor = NativeIntentExecutor();
      final result = await executor.handleIntent('send_email', 'not json');
      expect(result, isA<ErrorResult>());
      expect((result as ErrorResult).message, contains('Invalid parameters'));
    });

    test('a throwing handler is caught and surfaced as ErrorResult', () async {
      final executor = NativeIntentExecutor(
        handlers: {'send_email': (_) async => throw StateError('boom')},
      );
      final result = await executor.handleIntent(
        'send_email',
        '{"extra_email": "a@b.com"}',
      );
      expect(result, isA<ErrorResult>());
      expect((result as ErrorResult).message, contains('failed'));
    });
  });

  group('validateIntentParams — send_email', () {
    test('valid email passes', () {
      expect(
        validateIntentParams('send_email', {
          'extra_email': 'jane@example.com',
          'extra_subject': 'Hi',
          'extra_text': 'Hello',
        }),
        isNull,
      );
    });

    test('missing email rejected', () {
      final err = validateIntentParams('send_email', {'extra_subject': 'Hi'});
      expect(err, isNotNull);
      expect(err, contains('extra_email'));
    });

    test('malformed email rejected', () {
      expect(
        validateIntentParams('send_email', {'extra_email': 'not-an-email'}),
        contains('invalid email'),
      );
      expect(
        validateIntentParams('send_email', {'extra_email': 'a@b'}),
        contains('invalid email'),
      );
    });

    test('non-string optional field rejected', () {
      final err = validateIntentParams('send_email', {
        'extra_email': 'a@b.com',
        'extra_subject': 42,
      });
      expect(err, contains('extra_subject'));
    });

    test(
      'handler validates before acting (bad email never reaches it)',
      () async {
        var ran = false;
        final executor = NativeIntentExecutor(
          handlers: {
            'send_email': (_) async {
              ran = true;
              return const TextResult('sent');
            },
          },
        );
        final result = await executor.handleIntent(
          'send_email',
          '{"extra_email": "garbage"}',
        );
        expect(result, isA<ErrorResult>());
        expect((result as ErrorResult).message, contains('Invalid parameters'));
        expect(ran, isFalse, reason: 'validation must gate the handler');
      },
    );
  });

  group('validateIntentParams — send_text', () {
    test('valid phone passes', () {
      expect(
        validateIntentParams('send_text', {
          'phone_number': '+1 (415) 555-2671',
          'sms_body': 'hi',
        }),
        isNull,
      );
    });

    test('missing phone rejected', () {
      expect(
        validateIntentParams('send_text', {'sms_body': 'hi'}),
        contains('phone_number'),
      );
    });

    test('too-short / non-numeric phone rejected', () {
      expect(
        validateIntentParams('send_text', {'phone_number': '12'}),
        contains('invalid phone'),
      );
      expect(
        validateIntentParams('send_text', {'phone_number': 'call-me'}),
        contains('invalid phone'),
      );
    });
  });

  group('validateIntentParams — create_calendar_event', () {
    test('valid event passes', () {
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'Standup',
          'description': 'Daily',
          'begin_time': '2026-06-26T09:00:00',
          'end_time': '2026-06-26T09:15:00',
        }),
        isNull,
      );
    });

    test('missing title rejected', () {
      final err = validateIntentParams('create_calendar_event', {
        'begin_time': '2026-06-26T09:00:00',
        'end_time': '2026-06-26T09:15:00',
      });
      expect(err, contains('title'));
    });

    test('non-ISO begin_time rejected', () {
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'X',
          'begin_time': 'tomorrow at noon',
          'end_time': '2026-06-26T09:15:00',
        }),
        contains('begin_time'),
      );
    });

    test('end before begin rejected', () {
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'X',
          'begin_time': '2026-06-26T10:00:00',
          'end_time': '2026-06-26T09:00:00',
        }),
        contains('after begin_time'),
      );
    });

    test('ISO begin_time without end_time passes (end defaults to +1h)', () {
      // Regression: small models often omit end_time; it must not be required.
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'Standup',
          'begin_time': '2026-06-26T09:00:00',
        }),
        isNull,
      );
    });

    test('relative form (day_offset/hour) passes without any ISO string', () {
      // The preferred shape for small models — integers only, no ISO to botch.
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'Lunch',
          'day_offset': 1,
          'hour': 12,
          'minute': 0,
          'duration_minutes': 90,
        }),
        isNull,
      );
    });

    test('relative form with only title + hour passes (rest defaults)', () {
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'Focus',
          'hour': 15,
        }),
        isNull,
      );
    });

    test('relative form rejects an out-of-range hour', () {
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'X',
          'hour': 25,
        }),
        contains('hour'),
      );
    });

    test('present-but-invalid begin_time errors (no silent 9am default)', () {
      // Regression: a begin_time that is present but not a valid ISO string must
      // NOT silently fall into the relative form (a default 9am-today event).
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'X',
          'begin_time': 12345, // a number, not a string
        }),
        contains('begin_time'),
      );
      expect(
        validateIntentParams('create_calendar_event', {
          'title': 'X',
          'begin_time': '', // empty string
        }),
        contains('begin_time'),
      );
    });
  });

  group('validateIntentParams — read_calendar_events', () {
    test('valid date passes', () {
      expect(
        validateIntentParams('read_calendar_events', {'date': '2026-06-26'}),
        isNull,
      );
    });

    test('missing / bad date rejected', () {
      expect(
        validateIntentParams('read_calendar_events', const {}),
        contains('date'),
      );
      expect(
        validateIntentParams('read_calendar_events', {'date': 'someday'}),
        contains('ISO-8601'),
      );
    });
  });

  group('validateIntentParams — schedule_notification', () {
    test('valid notification passes', () {
      expect(
        validateIntentParams('schedule_notification', {
          'title': 'Pills',
          'message': 'Take your meds',
          'hour': 8,
          'minute': 30,
        }),
        isNull,
      );
    });

    test('hour / minute out of range rejected', () {
      expect(
        validateIntentParams('schedule_notification', {
          'title': 'x',
          'message': 'y',
          'hour': 25,
          'minute': 0,
        }),
        contains('hour'),
      );
      expect(
        validateIntentParams('schedule_notification', {
          'title': 'x',
          'message': 'y',
          'hour': 8,
          'minute': 99,
        }),
        contains('minute'),
      );
    });

    test('missing message rejected', () {
      expect(
        validateIntentParams('schedule_notification', {
          'title': 'x',
          'hour': 8,
          'minute': 0,
        }),
        contains('message'),
      );
    });

    test('optional explicit date validated when present', () {
      expect(
        validateIntentParams('schedule_notification', {
          'title': 'x',
          'message': 'y',
          'hour': 8,
          'minute': 0,
          'year': 2026,
          'month': 13, // invalid
          'day': 1,
        }),
        contains('month'),
      );
      expect(
        validateIntentParams('schedule_notification', {
          'title': 'x',
          'message': 'y',
          'hour': 8,
          'minute': 0,
          'year': 2026,
          'month': 6,
          'day': 26,
        }),
        isNull,
      );
    });
  });

  group('validateIntentParams — misc', () {
    test('get_current_date_and_time needs no params', () {
      expect(
        validateIntentParams('get_current_date_and_time', const {}),
        isNull,
      );
    });

    test('unknown intent is reported as unknown', () {
      expect(
        validateIntentParams('launch_missiles', const {}),
        contains('unknown intent'),
      );
    });
  });

  group('get_current_date_and_time — pure Dart', () {
    test('formats a fixed DateTime like Gallery (ISO + weekday)', () {
      // 2026-06-26 is a Friday.
      final stamp = currentDateAndTime(DateTime(2026, 6, 26, 14, 5, 9));
      expect(stamp, '2026-06-26T14:05:09 Friday');
    });

    test('zero-pads single-digit components', () {
      final stamp = currentDateAndTime(DateTime(2026, 1, 2, 3, 4, 5));
      // 2026-01-02 is a Friday.
      expect(stamp, '2026-01-02T03:04:05 Friday');
    });

    test('executor get_current_date_and_time returns a TextResult', () async {
      final executor = NativeIntentExecutor();
      final result = await executor.handleIntent(
        'get_current_date_and_time',
        '',
      );
      expect(result, isA<TextResult>());
      expect(
        (result as TextResult).text,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T')),
      );
    });
  });
}
