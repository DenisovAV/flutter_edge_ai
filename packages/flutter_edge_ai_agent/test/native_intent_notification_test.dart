import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_edge_ai_agent/src/executors/next_occurrence.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The method channel flutter_local_notifications' Android, iOS and macOS
/// implementations talk to (`platform_flutter_local_notifications.dart`).
const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

/// Stands in for a platform implementation that does not use the channel
/// (Linux talks D-Bus): records any scheduling call that reaches it.
class _RecordingPlatform extends fln.FlutterLocalNotificationsPlatform {
  final calls = <String>[];

  @override
  Future<void> zonedSchedule({
    required int id,
    String? title,
    String? body,
    required tz.TZDateTime scheduledDate,
    String? payload,
    fln.DateTimeComponents? matchDateTimeComponents,
  }) async {
    calls.add('zonedSchedule');
  }
}

/// 32-bit FNV-1a of [text], masked to 31 bits: the id the intent must give a
/// reminder, written independently of the executor's arithmetic.
int _fnv1a31(String text) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(text)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// A channel as flutter_local_notifications' Android side reports it.
Map<String, Object?> _channelMap(String id, String name, int importance) => {
  'id': id,
  'name': name,
  'importance': importance,
  'showBadge': true,
  'bypassDnd': false,
  'playSound': true,
  'enableLights': false,
  'enableVibration': true,
  'ledColor': 0,
  'audioAttributesUsage': 5,
};

const _reminder = {
  'title': 'Pills',
  'message': 'Take your meds',
  'hour': 8,
  'minute': 30,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every call that reached the channel, in order.
  late List<MethodCall> calls;

  /// What the fake native side answers, by method name.
  late Map<String, Object?> replies;

  setUpAll(tzdata.initializeTimeZones);

  setUp(() {
    calls = [];
    replies = {
      'areNotificationsEnabled': true,
      'canScheduleExactNotifications': true,
      'checkPermissions': <String, Object?>{'isEnabled': true},
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return replies[call.method];
        });
    // The app's own time zone, which the intent must leave alone.
    tz.setLocalLocation(tz.getLocation('America/Detroit'));
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  List<String> methods() => [for (final call in calls) call.method];

  Map<Object?, Object?> scheduledArgs() =>
      calls.singleWhere((c) => c.method == 'zonedSchedule').arguments
          as Map<Object?, Object?>;

  Future<SkillResult> schedule(
    NativeIntentExecutor executor, [
    Map<String, Object?> params = _reminder,
  ]) => executor.handleIntent('schedule_notification', jsonEncode(params));

  void onAndroid() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fln.AndroidFlutterLocalNotificationsPlugin.registerWith();
  }

  group('schedule_notification — opt-in', () {
    test('unconfigured: refused, and nothing reaches the plugin', () async {
      onAndroid();

      final result = await schedule(NativeIntentExecutor());

      expect(result, isA<ErrorResult>());
      expect(
        (result as ErrorResult).message,
        allOf(
          contains('NativeIntentExecutor(notifications:'),
          contains('initializes flutter_local_notifications itself'),
        ),
      );
      expect(calls, isEmpty);
    });

    test('empty settings strings are refused when the executor is built', () {
      for (final settings in const [
        NotificationIntentSettings(androidChannelId: ''),
        NotificationIntentSettings(androidChannelName: ' '),
        NotificationIntentSettings(androidSmallIcon: ''),
      ]) {
        expect(
          () => NativeIntentExecutor(notifications: settings),
          throwsA(isA<ArgumentError>()),
        );
      }
    });

    test('notifications: with a schedule_notification handler throws', () {
      expect(
        () => NativeIntentExecutor(
          notifications: const NotificationIntentSettings(),
          handlers: {
            'schedule_notification': (_) async => const TextResult('mine'),
          },
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.invalidValue,
            'invalidValue',
            'schedule_notification',
          ),
        ),
      );
      // Other handlers combine with it.
      expect(
        () => NativeIntentExecutor(
          notifications: const NotificationIntentSettings(),
          handlers: {'start_timer': (_) async => const TextResult('ok')},
        ),
        returnsNormally,
      );
    });
  });

  group('schedule_notification — Android', () {
    test('schedules in UTC with the app icon and channel; never initializes '
        'or prompts', () async {
      onAndroid();
      final executor = NativeIntentExecutor(
        notifications: const NotificationIntentSettings(
          androidSmallIcon: 'ic_agent',
          androidChannelId: 'reminders',
          androidChannelName: 'Reminders',
        ),
      );

      final result = await schedule(executor);

      expect(result, isA<TextResult>());
      expect(methods(), [
        'areNotificationsEnabled',
        'getNotificationChannels',
        'canScheduleExactNotifications',
        'zonedSchedule',
      ]);
      expect(
        methods().where((m) => m == 'initialize' || m.startsWith('request')),
        isEmpty,
      );
      final args = scheduledArgs();
      final specifics = args['platformSpecifics']! as Map<Object?, Object?>;
      expect(specifics['icon'], 'ic_agent');
      expect(specifics['channelId'], 'reminders');
      expect(specifics['channelName'], 'Reminders');
      expect(specifics['scheduleMode'], 'exactAllowWhileIdle');
      expect(args['timeZoneName'], tz.UTC.name);
      // The UTC instant is the requested local wall-clock time.
      final fireAt = DateTime.parse(
        args['scheduledDateTimeISO8601']! as String,
      ).toLocal();
      expect((fireAt.hour, fireAt.minute), (8, 30));
      expect(fireAt.isAfter(DateTime.now()), isTrue);
      // Reported back as local wall-clock time, not a UTC ISO string.
      expect(
        (result as TextResult).text,
        matches(
          RegExp(
            r'^Scheduled a notification "Pills" for '
            r'\d{4}-\d{2}-\d{2} 08:30 \([A-Z][a-z]+day\)\.$',
          ),
        ),
      );
    });

    test("leaves the app's tz.local alone", () async {
      onAndroid();

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<TextResult>());
      expect(tz.local.name, 'America/Detroit');
    });

    test('notifications turned off: refused, nothing scheduled', () async {
      onAndroid();
      replies['areNotificationsEnabled'] = false;

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<ErrorResult>());
      expect(
        (result as ErrorResult).message,
        contains('Notifications are turned off'),
      );
      expect(methods(), ['areNotificationsEnabled']);
    });

    test('the user blocked the channel: refused, nothing scheduled', () async {
      onAndroid();
      replies['getNotificationChannels'] = [
        _channelMap('other', 'Other', 4),
        _channelMap('agent_skill_tasks_channel', 'Agent reminders', 0),
      ];

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<ErrorResult>());
      expect(
        (result as ErrorResult).message,
        contains('"Agent reminders" notifications'),
      );
      expect(methods(), ['areNotificationsEnabled', 'getNotificationChannels']);
    });

    test('a channel that exists and is on schedules', () async {
      onAndroid();
      replies['getNotificationChannels'] = [
        _channelMap('agent_skill_tasks_channel', 'Agent reminders', 3),
      ];

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<TextResult>());
    });

    test('exact alarms not permitted: refused with the three fixes', () async {
      onAndroid();
      replies['canScheduleExactNotifications'] = false;

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<ErrorResult>());
      expect(
        (result as ErrorResult).message,
        allOf(
          contains('requestExactAlarmsPermission()'),
          contains('USE_EXACT_ALARM'),
          contains('androidExactAlarm: false'),
        ),
      );
      expect(methods(), [
        'areNotificationsEnabled',
        'getNotificationChannels',
        'canScheduleExactNotifications',
      ]);
    });

    test('androidExactAlarm: false schedules inexact without asking about '
        'exact alarms', () async {
      onAndroid();
      replies['canScheduleExactNotifications'] = false;

      final result = await schedule(
        NativeIntentExecutor(
          notifications: const NotificationIntentSettings(
            androidExactAlarm: false,
          ),
        ),
      );

      expect(result, isA<TextResult>());
      expect(methods(), [
        'areNotificationsEnabled',
        'getNotificationChannels',
        'zonedSchedule',
      ]);
      final specifics =
          scheduledArgs()['platformSpecifics']! as Map<Object?, Object?>;
      expect(specifics['scheduleMode'], 'inexactAllowWhileIdle');
      expect(specifics['channelId'], 'agent_skill_tasks_channel');
      expect(specifics.containsKey('icon'), isTrue);
      expect(specifics['icon'], isNull, reason: "the app's default icon");
    });

    test('no Android implementation registered: refused', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final other = _RecordingPlatform();
      fln.FlutterLocalNotificationsPlatform.instance = other;

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(
        (result as ErrorResult).message,
        contains('no Android implementation'),
      );
      expect(other.calls, isEmpty);
      expect(calls, isEmpty);
    });
  });

  group('schedule_notification — iOS and macOS', () {
    test('iOS without permission: refused, nothing scheduled', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fln.IOSFlutterLocalNotificationsPlugin.registerWith();
      replies['checkPermissions'] = <String, Object?>{
        'isEnabled': false,
        'isProvisionalEnabled': false,
      };

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<ErrorResult>());
      expect(
        (result as ErrorResult).message,
        contains('Notifications are not allowed'),
      );
      expect(methods(), ['checkPermissions']);
    });

    test('iOS with provisional permission: scheduled in UTC', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fln.IOSFlutterLocalNotificationsPlugin.registerWith();
      replies['checkPermissions'] = <String, Object?>{
        'isEnabled': false,
        'isProvisionalEnabled': true,
      };

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<TextResult>());
      expect(
        (result as TextResult).text,
        contains('quietly'),
        reason: 'provisional notifications show no banner and play no sound',
      );
      expect(methods(), ['checkPermissions', 'zonedSchedule']);
      expect(scheduledArgs()['timeZoneName'], tz.UTC.name);
    });

    test(
      'iOS with full permission says nothing about quiet delivery',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        fln.IOSFlutterLocalNotificationsPlugin.registerWith();

        final result = await schedule(
          NativeIntentExecutor(
            notifications: const NotificationIntentSettings(),
          ),
        );

        expect((result as TextResult).text, isNot(contains('quietly')));
      },
    );

    test('macOS without permission: refused, nothing scheduled', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      fln.MacOSFlutterLocalNotificationsPlugin.registerWith();
      replies['checkPermissions'] = <String, Object?>{'isEnabled': false};

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<ErrorResult>());
      expect(methods(), ['checkPermissions']);
    });
  });

  group('schedule_notification — unsupported platforms', () {
    test('Linux: refused before any plugin call', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final linux = _RecordingPlatform();
      fln.FlutterLocalNotificationsPlatform.instance = linux;

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
      );

      expect(result, isA<ErrorResult>());
      expect(
        (result as ErrorResult).message,
        contains('not supported on Linux'),
      );
      expect(linux.calls, isEmpty);
      expect(calls, isEmpty);
    });
  });

  group('schedule_notification — dates and ids', () {
    test('a partial date is refused before the handler runs', () async {
      onAndroid();
      expect(
        validateIntentParams('schedule_notification', {
          ..._reminder,
          'day': 20,
        }),
        'year, month and day go together or not at all: '
        'got day without year, month.',
      );

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
        {..._reminder, 'day': 20},
      );

      expect(result, isA<ErrorResult>());
      expect(calls, isEmpty);
    });

    test('February 31 is refused, not rolled into March', () {
      expect(
        validateIntentParams('schedule_notification', {
          ..._reminder,
          'year': 2027,
          'month': 2,
          'day': 31,
        }),
        'day 31 does not exist: month 2 of 2027 has 28 days.',
      );
      expect(
        validateIntentParams('schedule_notification', {
          ..._reminder,
          'year': 2028,
          'month': 2,
          'day': 29,
        }),
        isNull,
        reason: '2028 is a leap year',
      );
    });

    test('a time in the past is refused before any plugin call', () async {
      onAndroid();

      final result = await schedule(
        NativeIntentExecutor(notifications: const NotificationIntentSettings()),
        {..._reminder, 'year': 2020, 'month': 1, 'day': 15},
      );

      expect(
        (result as ErrorResult).message,
        'The requested time 2020-01-15 08:30 (Wednesday) is in the past; '
        'ask for a time that has not passed yet.',
      );
      expect(calls, isEmpty);
    });

    test('two reminders in the same minute get different ids; the same one '
        'keeps its id', () async {
      onAndroid();
      final executor = NativeIntentExecutor(
        notifications: const NotificationIntentSettings(),
      );

      Future<int> idOf(String title) async {
        calls.clear();
        expect(
          await schedule(executor, {..._reminder, 'title': title}),
          isA<TextResult>(),
        );
        return scheduledArgs()['id']! as int;
      }

      final pills = await idOf('Pills');
      final water = await idOf('Water');
      final pillsAgain = await idOf('Pills');

      expect(water, isNot(pills));
      expect(pillsAgain, pills);
      expect(pills, inInclusiveRange(0, 0x7fffffff));
      // The reference hash itself: FNV-1a("a") is 0xe40c292c.
      expect(_fnv1a31('a'), 0x640c292c);
      final fireAt = DateTime.parse(
        scheduledArgs()['scheduledDateTimeISO8601']! as String,
      );
      expect(
        pills,
        _fnv1a31(
          '${fireAt.millisecondsSinceEpoch ~/ 1000}|Pills|Take your meds',
        ),
      );
    });

    test('tomorrow keeps the wall-clock time across a clock change', () {
      // Europe/Berlin turns its clocks back in the night to 2026-10-25 and
      // forward in the night to 2026-03-29: 24 hours after 08:00 is 07:00 or
      // 09:00 there. Only a zone with daylight saving time tells the two
      // apart, so run this file under TZ=Europe/Berlin to see a regression.
      for (final evening in [
        DateTime(2026, 10, 24, 20),
        DateTime(2026, 3, 28, 20),
      ]) {
        final when = nextOccurrence(hour: 8, minute: 0, now: evening);
        expect(
          (when.month, when.day, when.hour, when.minute),
          (evening.month, evening.day + 1, 8, 0),
        );
      }
      final later = nextOccurrence(
        hour: 21,
        minute: 15,
        now: DateTime(2026, 10, 24, 20),
      );
      expect((later.day, later.hour, later.minute), (24, 21, 15));
    });
  });
}
