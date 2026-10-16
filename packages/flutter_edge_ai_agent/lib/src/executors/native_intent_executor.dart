import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../skill.dart';
import '../skill_executor.dart';
import '../skill_result.dart';
import 'notification_intent_settings.dart';
// add_2_calendar transitively imports dart:io (web-incompatible), so it is
// reached only via this conditional-import seam.
import 'native_intent_calendar_stub.dart'
    if (dart.library.io) 'native_intent_calendar_io.dart'
    as calendar;

/// Runs a single whitelisted native intent given its already-decoded
/// [params] (the model-supplied `parameters` JSON). [NativeIntentExecutor]
/// validates them before a handler is invoked: a built-in intent with
/// [validateIntentParams], then with the app's [IntentValidator] if it gave
/// one; an intent the app added only with the validator it gave.
typedef IntentHandler =
    Future<SkillResult> Function(Map<String, dynamic> params);

/// Checks one intent's decoded [params] before its handler runs: null when
/// they are valid, otherwise the reason, which is fed back to the model. The
/// same contract as [validateIntentParams].
typedef IntentValidator = String? Function(Map<String, dynamic> params);

/// The native-intent [SkillExecutor] — the agent's bridge to the device for
/// `SkillType.intent` skills (Gallery's `run_intent`).
///
/// SECURITY MODEL (no foreign code, unlike JS skills):
///
/// 1. **Whitelist.** Only an intent with a handler can run: the six
///    Gallery-parity built-ins in [_defaultHandlers] — [send_email],
///    [send_text], [create_calendar_event], [read_calendar_events],
///    [schedule_notification], [get_current_date_and_time] — and the intents
///    the app adds through [handlers]. An unknown intent returns an
///    [ErrorResult] and NEVER reaches a handler.
/// 2. **Parameter validation.** A built-in intent's parameters are validated
///    (presence, type, email/phone/ISO-8601 shape, time-component ranges) by
///    [validateIntentParams] BEFORE its handler runs — a malformed call
///    returns an [ErrorResult], not a half-built action. A validator the app
///    passes in [validators] for a built-in intent runs after that check, and
///    both must pass. An intent the app adds is validated only by the
///    validator it gives; without one, its handler gets the decoded parameters
///    unchecked.
/// 3. **OS / user confirmation.** Outbound / destructive actions go through the
///    OS compose / confirm surface (`url_launcher` opens the system mail / SMS
///    composer; `add_2_calendar` opens the calendar's event editor). The model
///    proposes; the **user** is the one who presses send / save. Nothing fires
///    silently.
///
/// Handlers are injectable (the [handlers] constructor arg overrides specific
/// intents and adds new ones) so the plugins can be mocked in tests and the
/// host app can provide richer implementations (e.g. a real device-calendar
/// reader) for intents the built-in defaults only stub, or intents of its own.
///
/// [scheduleNotification] is off until the app passes
/// [NotificationIntentSettings]: the app initializes
/// `flutter_local_notifications` itself, and the executor never does.
class NativeIntentExecutor extends SkillExecutor {
  /// Build the executor. [handlers], if given, override the built-in default
  /// handler for the matching intent name and add every other name as a new
  /// intent (the built-ins without an override keep their defaults). This is
  /// the seam tests use to inject fakes and apps use to extend.
  ///
  /// [validators] check an intent's parameters before its handler runs (see
  /// [IntentValidator]). One for a built-in intent runs after
  /// [validateIntentParams], whether or not its handler is replaced; both must
  /// pass. Throws [ArgumentError] when a validator names an intent that has no
  /// handler, built-in or added.
  ///
  /// [notifications] turns on the built-in [scheduleNotification]; without
  /// it that intent returns an [ErrorResult] and makes no plugin call. See
  /// [NotificationIntentSettings] for what the app sets up first. Throws
  /// [ArgumentError] when [handlers] also replaces [scheduleNotification]:
  /// the settings would configure a handler that never runs.
  NativeIntentExecutor({
    Map<String, IntentHandler>? handlers,
    Map<String, IntentValidator>? validators,
    NotificationIntentSettings? notifications,
  }) : _handlers = {
         ..._defaultHandlers,
         if (notifications != null)
           scheduleNotification: (params) =>
               _handleScheduleNotification(params, notifications),
         ...?handlers,
       },
       _validators = {...?validators} {
    if (notifications != null &&
        (handlers?.containsKey(scheduleNotification) ?? false)) {
      throw ArgumentError.value(
        scheduleNotification,
        'handlers',
        'replaces the built-in intent that notifications: configures; '
            'pass one or the other',
      );
    }
    for (final intent in _validators.keys) {
      if (!_handlers.containsKey(intent)) {
        throw ArgumentError.value(
          intent,
          'validators',
          'names an intent with no handler; add it to handlers: too',
        );
      }
    }
  }

  /// The built-in intent names (Gallery parity). Apps add more through the
  /// constructor's `handlers:`.
  static const String sendEmail = 'send_email';
  static const String sendText = 'send_text';
  static const String createCalendarEvent = 'create_calendar_event';
  static const String readCalendarEvents = 'read_calendar_events';
  static const String scheduleNotification = 'schedule_notification';
  static const String getCurrentDateAndTime = 'get_current_date_and_time';

  final Map<String, IntentHandler> _handlers;

  final Map<String, IntentValidator> _validators;

  @override
  String get name => 'NativeIntentExecutor';

  /// Probes by [SkillType.intent]. The concrete intent name (e.g. `send_email`)
  /// is resolved at [execute] time from the skill name or the data payload, and
  /// checked against the whitelist there.
  @override
  bool canExecuteSkill(Skill skill) => skill.type == SkillType.intent;

  /// The whitelisted intent names this executor can run.
  Iterable<String> get whitelistedIntents => _handlers.keys;

  /// Whether [intent] is a whitelisted action.
  bool isWhitelisted(String intent) => _handlers.containsKey(intent);

  @override
  Future<SkillResult> execute(
    Skill skill,
    String dataJson, {
    String? secret,
  }) async {
    // The agent loop hands intents in as a synthetic Skill whose name is the
    // intent (set from the model's `intent` tool arg) and a `dataJson` that is
    // the model's `parameters` JSON. As a fallback (and for direct callers that
    // embed everything in one payload) we also accept a top-level `intent` key
    // inside the data payload.
    final parsed = _decodeObject(dataJson);
    if (parsed == null) {
      return ErrorResult(
        'Invalid parameters: expected a JSON object, got: $dataJson',
      );
    }

    var intent = skill.name.trim();
    var params = parsed;
    if (!isWhitelisted(intent)) {
      // Fall back to an `intent` field carried inside the data payload.
      final inner = parsed['intent'];
      if (inner is String && inner.trim().isNotEmpty) {
        intent = inner.trim();
        final innerParams = parsed['parameters'];
        if (innerParams is Map<String, dynamic>) {
          params = innerParams;
        } else if (innerParams is String) {
          final reparsed = _decodeObject(innerParams);
          if (reparsed == null) {
            // The inner "parameters" was a string but not valid JSON. Surface it
            // instead of silently validating the outer wrapper map (which would
            // produce a confusing "missing field" error, or worse, run the
            // intent with the wrong parameters).
            return ErrorResult(
              'Invalid parameters for "$intent": "parameters" was a string but '
              'not valid JSON: $innerParams',
            );
          }
          params = reparsed;
        }
      }
    }

    return _run(intent, params);
  }

  /// Run a whitelisted [intent] from an already-encoded [parametersJson]. The
  /// direct, plugin-free entry point used by unit tests and host code that has
  /// the intent name in hand (the agent loop goes through [execute]).
  Future<SkillResult> handleIntent(String intent, String parametersJson) async {
    final params = _decodeObject(parametersJson);
    if (params == null) {
      return ErrorResult(
        'Invalid parameters: expected a JSON object, got: $parametersJson',
      );
    }
    return _run(intent, params);
  }

  /// Whitelist check → parameter validation → handler dispatch.
  Future<SkillResult> _run(String intent, Map<String, dynamic> params) async {
    final handler = _handlers[intent];
    if (handler == null) {
      return ErrorResult(
        'Unknown intent "$intent". Allowed intents: '
        '${whitelistedIntents.join(', ')}.',
      );
    }

    // A built-in intent's own check first, whether or not its handler was
    // replaced (the default handlers read the fields it guarantees), then the
    // app's validator; both must pass. An intent the app added without a
    // validator has none. A validator that throws fails the call like a
    // handler that throws.
    try {
      final validationError =
          (_defaultHandlers.containsKey(intent)
              ? validateIntentParams(intent, params)
              : null) ??
          _validators[intent]?.call(params);
      if (validationError != null) {
        return ErrorResult(
          'Invalid parameters for "$intent": $validationError',
        );
      }
      return await handler(params);
    } catch (e) {
      return ErrorResult('Intent "$intent" failed: $e');
    }
  }

  /// The built-in handlers — one per whitelisted intent. Plugin-backed handlers
  /// guard their platform-specific calls; on an unsupported platform they
  /// return an [ErrorResult] rather than throw, so the model can recover and
  /// the package stays compile-clean on all six targets. The
  /// [scheduleNotification] entry here is the unconfigured one; the
  /// constructor replaces it when the app passes [NotificationIntentSettings].
  static final Map<String, IntentHandler> _defaultHandlers = {
    sendEmail: _handleSendEmail,
    sendText: _handleSendText,
    createCalendarEvent: _handleCreateCalendarEvent,
    readCalendarEvents: _handleReadCalendarEvents,
    scheduleNotification: (params) => _handleScheduleNotification(params, null),
    getCurrentDateAndTime: _handleGetCurrentDateAndTime,
  };

  // --- default handlers -----------------------------------------------------

  /// `send_email` → opens the OS mail composer via a `mailto:` URI. The user
  /// reviews and presses send; nothing is sent silently.
  static Future<SkillResult> _handleSendEmail(
    Map<String, dynamic> params,
  ) async {
    final to = (params['extra_email'] as String).trim();
    final subject = (params['extra_subject'] as String?) ?? '';
    final body = (params['extra_text'] as String?) ?? '';
    final uri = Uri(
      scheme: 'mailto',
      path: to,
      query: _encodeQuery({'subject': subject, 'body': body}),
    );
    return _launch(uri, 'mail composer');
  }

  /// `send_text` → opens the OS SMS composer via an `sms:` URI. The user
  /// reviews and presses send.
  static Future<SkillResult> _handleSendText(
    Map<String, dynamic> params,
  ) async {
    final phone = (params['phone_number'] as String).trim();
    final body = (params['sms_body'] as String?) ?? '';
    final uri = Uri(
      scheme: 'sms',
      path: phone,
      query: _encodeQuery({'body': body}),
    );
    return _launch(uri, 'SMS composer');
  }

  /// `create_calendar_event` → opens the calendar's event editor. On Android /
  /// iOS via `add_2_calendar`; elsewhere via a Google Calendar template URL the
  /// browser opens. Either way the user confirms the save.
  static Future<SkillResult> _handleCreateCalendarEvent(
    Map<String, dynamic> params,
  ) async {
    final title = params['title'] as String;
    final description = (params['description'] as String?) ?? '';
    final (begin, end) = _calendarTimes(params);

    final isMobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (isMobile) {
      return calendar.addCalendarEvent(
        title: title,
        description: description,
        begin: begin,
        end: end,
      );
    }

    // Desktop / web fallback: Google Calendar event-template URL.
    final fmt = _googleCalendarStamp;
    final uri = Uri.parse(
      'https://calendar.google.com/calendar/render'
      '?action=TEMPLATE'
      '&text=${Uri.encodeQueryComponent(title)}'
      '&details=${Uri.encodeQueryComponent(description)}'
      '&dates=${fmt(begin)}/${fmt(end)}',
    );
    return _launch(uri, 'calendar');
  }

  /// Resolve a calendar event's (begin, end) from either of two shapes:
  ///
  ///  * **relative** (preferred — small models can't reliably emit ISO-8601):
  ///    `day_offset` (0 = today, 1 = tomorrow, …), `hour`, `minute` (default 0),
  ///    `duration_minutes` (default 60). The executor does the date math, so the
  ///    model only supplies integers — no year arithmetic, no string formatting.
  ///  * **absolute** (Gallery-compatible): explicit ISO-8601 `begin_time` /
  ///    `end_time`. Used when present; if `end_time` is missing it defaults to
  ///    one hour after `begin_time`.
  static (DateTime, DateTime) _calendarTimes(Map<String, dynamic> params) {
    final beginRaw = params['begin_time'];
    if (beginRaw is String && beginRaw.trim().isNotEmpty) {
      final begin = DateTime.parse(beginRaw);
      final endRaw = params['end_time'];
      final end = (endRaw is String && endRaw.trim().isNotEmpty)
          ? DateTime.parse(endRaw)
          : begin.add(const Duration(hours: 1));
      return (begin, end);
    }
    // Relative form.
    final now = DateTime.now();
    final offset = (params['day_offset'] as num?)?.toInt() ?? 0;
    final hour = (params['hour'] as num?)?.toInt() ?? 9;
    final minute = (params['minute'] as num?)?.toInt() ?? 0;
    final duration = (params['duration_minutes'] as num?)?.toInt() ?? 60;
    // Put the offset in the day component so the constructor normalizes to the
    // requested wall-clock time on the target day. Using .add(Duration(days:))
    // instead would add an absolute 24h per day, drifting the hour by ±1 across
    // a DST transition. (The day field overflows into month/year correctly.)
    final begin = DateTime(now.year, now.month, now.day + offset, hour, minute);
    return (begin, begin.add(Duration(minutes: duration)));
  }

  /// `read_calendar_events` → reading the device calendar needs a
  /// platform-specific permissioned plugin that the cross-platform default does
  /// not bundle. Validates the date and returns a clear, recoverable error;
  /// host apps inject a real reader via the [handlers] constructor arg.
  static Future<SkillResult> _handleReadCalendarEvents(
    Map<String, dynamic> params,
  ) async {
    return ErrorResult(
      'Reading calendar events is not available with the built-in handler on '
      'this platform. Provide a custom "$readCalendarEvents" handler to '
      'NativeIntentExecutor to enable it. Requested date: ${params['date']}.',
    );
  }

  /// `schedule_notification` → schedules a local notification at the requested
  /// time via `flutter_local_notifications`. The OS shows it; nothing private
  /// leaves the device.
  ///
  /// Runs only with [settings] (the app's [NotificationIntentSettings]): the
  /// app has initialized the plugin and owns the permission prompts. This
  /// handler never calls `initialize` or a `request*` method; it checks the
  /// permissions and refuses with an [ErrorResult] when they are missing.
  static Future<SkillResult> _handleScheduleNotification(
    Map<String, dynamic> params,
    NotificationIntentSettings? settings,
  ) async {
    final title = params['title'] as String;
    final message = params['message'] as String;
    final hour = (params['hour'] as num).toInt();
    final minute = (params['minute'] as num).toInt();

    // validateIntentParams guarantees year, month and day together or none.
    final when = _nextOccurrence(
      hour: hour,
      minute: minute,
      year: (params['year'] as num?)?.toInt(),
      month: (params['month'] as num?)?.toInt(),
      day: (params['day'] as num?)?.toInt(),
    );

    if (settings == null) {
      return ErrorResult(
        'Scheduling notifications is not enabled in this app. To enable it, '
        'the app initializes flutter_local_notifications itself and passes '
        'NativeIntentExecutor(notifications: NotificationIntentSettings(...)). '
        'Requested: "$title" at ${_wallClock(when)}.',
      );
    }
    if (kIsWeb) return ErrorResult(_noScheduledNotificationsOn('the web'));
    if (!when.isAfter(DateTime.now())) {
      return ErrorResult(
        'The requested time ${_wallClock(when)} is in the past; '
        'ask for a time that has not passed yet.',
      );
    }

    final plugin = fln.FlutterLocalNotificationsPlugin();
    final refusal = switch (defaultTargetPlatform) {
      TargetPlatform.android => await _androidRefusal(plugin, settings),
      TargetPlatform.iOS => await _darwinRefusal(
        plugin
            .resolvePlatformSpecificImplementation<
              fln.IOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions(),
        'iOS',
      ),
      TargetPlatform.macOS => await _darwinRefusal(
        plugin
            .resolvePlatformSpecificImplementation<
              fln.MacOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions(),
        'macOS',
      ),
      // flutter_local_notifications has no permission query on Windows; the
      // app's initialize is what the plugin needs there.
      TargetPlatform.windows => null,
      TargetPlatform.linux => _noScheduledNotificationsOn('Linux'),
      TargetPlatform.fuchsia => _noScheduledNotificationsOn('Fuchsia'),
    };
    if (refusal != null) return ErrorResult(refusal);

    final details = fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        settings.androidChannelId,
        settings.androidChannelName,
        icon: settings.androidSmallIcon,
        importance: fln.Importance.defaultImportance,
      ),
      iOS: const fln.DarwinNotificationDetails(),
      macOS: const fln.DarwinNotificationDetails(),
    );

    // The instant in UTC: tz.UTC is a fixed location that needs no time zone
    // database. Loading the database (initializeTimeZones) would reset the
    // app's tz.local to UTC, and tz.local is the app's, not the agent's.
    await plugin.zonedSchedule(
      id: _notificationId(when, title, message),
      title: title,
      body: message,
      scheduledDate: tz.TZDateTime.from(when, tz.UTC),
      notificationDetails: details,
      androidScheduleMode: settings.androidExactAlarm
          ? fln.AndroidScheduleMode.exactAllowWhileIdle
          : fln.AndroidScheduleMode.inexactAllowWhileIdle,
    );
    return TextResult(
      'Scheduled a notification "$title" for ${_wallClock(when)}.',
    );
  }

  /// The refusal for a platform where flutter_local_notifications has no
  /// scheduled notifications (`zonedSchedule` throws there).
  static String _noScheduledNotificationsOn(String platform) =>
      'Scheduling notifications is not supported on $platform: '
      'flutter_local_notifications cannot schedule a notification there.';

  /// Why Android cannot take the notification now, or null when it can.
  /// Reads the state only; the prompts are the app's.
  static Future<String?> _androidRefusal(
    fln.FlutterLocalNotificationsPlugin plugin,
    NotificationIntentSettings settings,
  ) async {
    final android = plugin
        .resolvePlatformSpecificImplementation<
          fln.AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      return 'Scheduling notifications failed: flutter_local_notifications '
          'has no Android implementation registered in this app.';
    }
    if (await android.areNotificationsEnabled() != true) {
      return 'Notifications are turned off for this app, so the reminder '
          'would never show. The user can turn them on in the system '
          'settings; the app can ask with requestNotificationsPermission().';
    }
    if (settings.androidExactAlarm &&
        await android.canScheduleExactNotifications() != true) {
      return 'This app may not schedule exact alarms, so Android would refuse '
          'the reminder. The app can grant SCHEDULE_EXACT_ALARM via '
          'requestExactAlarmsPermission(), declare USE_EXACT_ALARM, or pass '
          'NotificationIntentSettings(androidExactAlarm: false) for an inexact '
          'reminder.';
    }
    return null;
  }

  /// Why iOS or macOS cannot show the notification, or null when it can.
  /// [check] is the platform implementation's `checkPermissions()`, null when
  /// none is registered; the permissions must allow notifications, fully or
  /// provisionally. Reads the state only; the prompts are the app's.
  static Future<String?> _darwinRefusal(
    Future<fln.NotificationsEnabledOptions?>? check,
    String platform,
  ) async {
    if (check == null) {
      return 'Scheduling notifications failed: flutter_local_notifications '
          'has no $platform implementation registered in this app.';
    }
    final permissions = await check;
    if (permissions == null) {
      return 'Scheduling notifications failed: flutter_local_notifications '
          'returned no permission state on $platform.';
    }
    if (permissions.isEnabled || permissions.isProvisionalEnabled) {
      return null;
    }
    return 'Notifications are not allowed for this app, so the reminder would '
        'never show. The user can allow them in the system settings; the app '
        'can ask with requestPermissions().';
  }

  /// `get_current_date_and_time` → pure Dart. No plugin, no platform branch.
  static Future<SkillResult> _handleGetCurrentDateAndTime(
    Map<String, dynamic> params,
  ) async {
    return TextResult(currentDateAndTime());
  }

  // --- helpers --------------------------------------------------------------

  /// Open [uri] in the OS, returning a [TextResult] on success or an
  /// [ErrorResult] when no app can handle it.
  static Future<SkillResult> _launch(Uri uri, String surface) async {
    if (!await launcher.canLaunchUrl(uri)) {
      return ErrorResult('No app available to open the $surface.');
    }
    final ok = await launcher.launchUrl(
      uri,
      mode: launcher.LaunchMode.externalApplication,
    );
    return ok
        ? TextResult('Opened the $surface for the user to confirm.')
        : ErrorResult('Could not open the $surface.');
  }

  /// `key=value&key=value` query with each value percent-encoded. Empty values
  /// are dropped so e.g. an empty SMS body produces a bare `sms:` URI.
  ///
  /// `encodeComponent`, not `encodeQueryComponent`: a `mailto:` or `sms:`
  /// URI is not a form, so a `+` stays a plus sign (RFC 6068) and a space
  /// has to be `%20` — what url_launcher's README prescribes for these
  /// schemes.
  static String _encodeQuery(Map<String, String> params) {
    return params.entries
        .where((e) => e.value.isNotEmpty)
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}='
              '${Uri.encodeComponent(e.value)}',
        )
        .join('&');
  }

  /// `yyyyMMddTHHmmssZ` (UTC) for a Google Calendar template URL. The template's
  /// `dates=` param treats a bare `yyyyMMddTHHmmss` (no `Z`) as UTC, so emitting
  /// local wall-clock components there shifts the event by the local offset
  /// (a UTC+3 user's 09:00 becomes 12:00). Convert to UTC and append `Z` so
  /// Google renders the correct local time.
  static String _googleCalendarStamp(DateTime d) {
    final u = d.toUtc();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${u.year}${p(u.month)}${p(u.day)}T'
        '${p(u.hour)}${p(u.minute)}${p(u.second)}Z';
  }

  /// `yyyy-MM-dd HH:mm (Weekday)` in [d]'s own (local) wall-clock time: what
  /// the user asked for, reported back to the model.
  static String _wallClock(DateTime d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)} '
        '(${_weekdays[d.weekday - 1]})';
  }

  /// The notification id: a 32-bit FNV-1a hash of the time, title and message,
  /// masked to 31 bits (the plugin takes a signed 32-bit id). Two different
  /// reminders in the same minute get different ids instead of replacing each
  /// other; the same reminder asked twice keeps its id, so it is replaced, not
  /// duplicated. [String.hashCode] is not stable across runs, so it is not
  /// used.
  static int _notificationId(DateTime when, String title, String message) {
    final epochSeconds = when.millisecondsSinceEpoch ~/ 1000;
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode('$epochSeconds|$title|$message')) {
      hash ^= byte;
      // hash * 16777619 (2^24 + 403), kept within 32 bits. Split so that no
      // intermediate exceeds 2^53 when compiled to JavaScript.
      hash = (hash * 403 + ((hash << 24) & 0xffffffff)) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  /// The next [DateTime] matching the given time-of-day. If an explicit date
  /// ([year]/[month]/[day]) is supplied it is honoured; otherwise the next
  /// occurrence today-or-tomorrow is chosen so a past time rolls forward.
  static DateTime _nextOccurrence({
    required int hour,
    required int minute,
    int? year,
    int? month,
    int? day,
  }) {
    final now = DateTime.now();
    if (year != null && month != null && day != null) {
      return DateTime(year, month, day, hour, minute);
    }
    var when = DateTime(now.year, now.month, now.day, hour, minute);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    return when;
  }
}

/// The current local date and time, formatted like Gallery's intent
/// (`yyyy-MM-ddTHH:mm:ss Weekday`). Pure Dart, exposed for direct/testable use.
String currentDateAndTime([DateTime? now]) {
  final d = now ?? DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)}T'
      '${p(d.hour)}:${p(d.minute)}:${p(d.second)} '
      '${_weekdays[d.weekday - 1]}';
}

/// [DateTime.weekday] 1-7 → name, Monday first.
const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Validate the [params] for one of the six built-in intents. Returns null when
/// valid, otherwise a human-readable reason. Pure (no I/O, no plugins) so it is
/// fully unit-testable and runs BEFORE any action is taken. Any other [intent]
/// is reported as unknown: [NativeIntentExecutor] does not call this for the
/// intents an app adds.
String? validateIntentParams(String intent, Map<String, dynamic> params) {
  switch (intent) {
    case NativeIntentExecutor.sendEmail:
      final email = params['extra_email'];
      if (email is! String || email.trim().isEmpty) {
        return 'missing required string "extra_email".';
      }
      if (!_isValidEmail(email.trim())) {
        return 'invalid email address "$email".';
      }
      return _ensureOptionalStrings(params, ['extra_subject', 'extra_text']);

    case NativeIntentExecutor.sendText:
      final phone = params['phone_number'];
      if (phone is! String || phone.trim().isEmpty) {
        return 'missing required string "phone_number".';
      }
      if (!_isValidPhone(phone.trim())) {
        return 'invalid phone number "$phone".';
      }
      return _ensureOptionalStrings(params, ['sms_body']);

    case NativeIntentExecutor.createCalendarEvent:
      final titleMissing = _requireStrings(params, ['title']);
      if (titleMissing != null) return titleMissing;
      final beginRaw = params['begin_time'];
      final hasIso = beginRaw is String && beginRaw.trim().isNotEmpty;
      // A begin_time that is PRESENT but not a valid non-empty ISO string is an
      // error — don't silently fall through to the relative form (which would
      // create a default 9am-today event the caller never asked for).
      if (!hasIso && params.containsKey('begin_time')) {
        return 'begin_time must be a non-empty ISO-8601 string when provided.';
      }
      if (hasIso) {
        // Absolute (Gallery) form: ISO begin_time; end_time optional (defaults
        // to +1h in the handler).
        final begin = DateTime.tryParse(beginRaw);
        if (begin == null) {
          return 'begin_time "$beginRaw" is not an ISO-8601 date-time.';
        }
        final endRaw = params['end_time'];
        if (endRaw is String && endRaw.trim().isNotEmpty) {
          final end = DateTime.tryParse(endRaw);
          if (end == null) {
            return 'end_time "$endRaw" is not an ISO-8601 date-time.';
          }
          if (!end.isAfter(begin)) {
            return 'end_time must be after begin_time.';
          }
        }
      } else {
        // Relative form: validate the integer fields' ranges (all optional; the
        // handler defaults day_offset=0, hour=9, minute=0, duration=60).
        final hourErr = _optionalIntInRange(params, 'hour', 0, 23);
        if (hourErr != null) return hourErr;
        final minErr = _optionalIntInRange(params, 'minute', 0, 59);
        if (minErr != null) return minErr;
        final offErr = _optionalIntInRange(params, 'day_offset', 0, 3650);
        if (offErr != null) return offErr;
        final durErr = _optionalIntInRange(params, 'duration_minutes', 1, 1440);
        if (durErr != null) return durErr;
      }
      return _ensureOptionalStrings(params, ['description']);

    case NativeIntentExecutor.readCalendarEvents:
      final date = params['date'];
      if (date is! String || date.trim().isEmpty) {
        return 'missing required string "date".';
      }
      if (DateTime.tryParse(date.trim()) == null) {
        return 'date "$date" is not an ISO-8601 date.';
      }
      return null;

    case NativeIntentExecutor.scheduleNotification:
      final missing = _requireStrings(params, ['title', 'message']);
      if (missing != null) return missing;
      final hourError = _requireIntInRange(params, 'hour', 0, 23);
      if (hourError != null) return hourError;
      final minuteError = _requireIntInRange(params, 'minute', 0, 59);
      if (minuteError != null) return minuteError;
      return _explicitDateError(params);

    case NativeIntentExecutor.getCurrentDateAndTime:
      // No parameters required.
      return null;

    default:
      return 'unknown intent.';
  }
}

/// A pragmatic email shape check (not RFC-5322 exhaustive): one `@`, a
/// non-empty local part, and a dotted domain with no whitespace.
bool _isValidEmail(String value) {
  final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  return re.hasMatch(value);
}

/// A lenient phone check: optional leading `+`, then 7–15 digits, allowing
/// spaces / dashes / parens as separators.
bool _isValidPhone(String value) {
  final digits = value.replaceAll(RegExp(r'[\s\-()]'), '');
  return RegExp(r'^\+?\d{7,15}$').hasMatch(digits);
}

/// Ensure every key in [required] is a non-empty string. Returns null if all
/// present, else a reason naming the first offender.
String? _requireStrings(Map<String, dynamic> params, List<String> required) {
  for (final key in required) {
    final v = params[key];
    if (v is! String || v.trim().isEmpty) {
      return 'missing required string "$key".';
    }
  }
  return null;
}

/// Ensure any present key in [optional] is a string (when supplied). Returns
/// null if all present-or-absent values are strings.
String? _ensureOptionalStrings(
  Map<String, dynamic> params,
  List<String> optional,
) {
  for (final key in optional) {
    if (params.containsKey(key) && params[key] is! String) {
      return 'optional field "$key" must be a string when provided.';
    }
  }
  return null;
}

/// Require an integer-valued key in `[min, max]`.
String? _requireIntInRange(
  Map<String, dynamic> params,
  String key,
  int min,
  int max,
) {
  final v = params[key];
  if (v is! num || v != v.toInt()) {
    return 'missing or non-integer "$key".';
  }
  final i = v.toInt();
  if (i < min || i > max) {
    return '"$key" must be between $min and $max (got $i).';
  }
  return null;
}

/// `schedule_notification`'s optional explicit date: `year`, `month` and `day`
/// all three or none (a null value counts as absent), and a day that exists
/// in that month — `DateTime` would roll February 31 into March.
String? _explicitDateError(Map<String, dynamic> params) {
  const keys = ['year', 'month', 'day'];
  final given = [
    for (final key in keys)
      if (params[key] != null) key,
  ];
  if (given.isEmpty) return null;
  if (given.length < keys.length) {
    final missing = keys.where((key) => !given.contains(key));
    return 'year, month and day go together or not at all: got '
        '${given.join(', ')} without ${missing.join(', ')}.';
  }
  final monthError = _requireIntInRange(params, 'month', 1, 12);
  if (monthError != null) return monthError;
  final dayError = _requireIntInRange(params, 'day', 1, 31);
  if (dayError != null) return dayError;
  final yearError = _requireIntInRange(params, 'year', 1970, 9999);
  if (yearError != null) return yearError;
  final year = (params['year'] as num).toInt();
  final month = (params['month'] as num).toInt();
  final day = (params['day'] as num).toInt();
  // Day 0 of the next month is the last day of this one.
  final daysInMonth = DateTime.utc(year, month + 1, 0).day;
  if (day > daysInMonth) {
    return 'day $day does not exist: month $month of $year has '
        '$daysInMonth days.';
  }
  return null;
}

/// Like [_requireIntInRange] but the key is optional; absent → ok.
String? _optionalIntInRange(
  Map<String, dynamic> params,
  String key,
  int min,
  int max,
) {
  if (!params.containsKey(key) || params[key] == null) return null;
  return _requireIntInRange(params, key, min, max);
}

/// Decode [json] into a `Map<String, dynamic>`, returning null on any failure
/// (non-JSON, or a non-object top level). An empty string decodes to an empty
/// map so a no-parameter intent works without an explicit `{}`.
Map<String, dynamic>? _decodeObject(String json) {
  final trimmed = json.trim();
  if (trimmed.isEmpty) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
