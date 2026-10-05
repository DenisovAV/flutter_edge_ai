import 'package:add_2_calendar/add_2_calendar.dart' as add2cal;

import '../skill_result.dart';

/// Native (`dart:io`) build of the calendar add-event hook.
///
/// `add_2_calendar` opens the OS calendar's event editor pre-filled with the
/// event — the user is the one who presses save. It transitively imports
/// `dart:io`, so it is reached only through the conditional-import seam (this
/// file on native, `native_intent_calendar_stub.dart` on web). The
/// `NativeIntentExecutor` only invokes this on Android / iOS (where
/// `add_2_calendar` has a platform implementation); other native targets get
/// the Google Calendar template-URL fallback.
Future<SkillResult> addCalendarEvent({
  required String title,
  required String description,
  required DateTime begin,
  required DateTime end,
}) async {
  final event = add2cal.Event(
    title: title,
    description: description,
    startDate: begin,
    endDate: end,
  );
  final added = await add2cal.Add2Calendar.addEvent2Cal(event);
  return added
      ? const TextResult('Opened the calendar event editor for the user.')
      : const ErrorResult('Could not open the calendar event editor.');
}
