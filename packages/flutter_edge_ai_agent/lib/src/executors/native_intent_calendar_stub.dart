import '../skill_result.dart';

/// Web (and any non-`dart:io`) build of the calendar add-event hook.
///
/// `add_2_calendar` transitively imports `dart:io`, which does not compile for
/// the web target, so it is reached only through this conditional-import seam
/// (`native_intent_calendar_io.dart` on native, this stub on web). On web the
/// `NativeIntentExecutor` never calls this — it routes `create_calendar_event`
/// to the Google Calendar template URL fallback instead — but the symbol must
/// exist so the package compiles for every platform.
Future<SkillResult> addCalendarEvent({
  required String title,
  required String description,
  required DateTime begin,
  required DateTime end,
}) async {
  return const ErrorResult(
    'The native calendar editor is not available on this platform.',
  );
}
