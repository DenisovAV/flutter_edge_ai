/// Settings that make `schedule_notification` usable. Passing them is the app
/// saying it has called `FlutterLocalNotificationsPlugin().initialize(...)`
/// itself (its own callbacks, its own default icon) and owns the permission
/// prompts; the agent only checks permissions and schedules.
///
/// The agent never calls `initialize`: a second call would replace the app's
/// callbacks, default icon and presentation options, and the plugin has no way
/// to tell whether it already ran. Without these settings the intent returns
/// an error and makes no plugin call. With them but no `initialize`, the
/// plugin crashes the app: on macOS when it schedules, on Android when the
/// reminder fires if [androidSmallIcon] is null.
///
/// Pass them as `NativeIntentExecutor(notifications: ...)`, which throws an
/// [ArgumentError] when one of the strings is empty.
final class NotificationIntentSettings {
  /// Settings for the built-in `schedule_notification` intent. Every field has
  /// a default, so `const NotificationIntentSettings()` is enough for an app
  /// whose `initialize` set an Android default icon and that may schedule exact
  /// alarms.
  const NotificationIntentSettings({
    this.androidSmallIcon,
    this.androidChannelId = 'agent_skill_tasks_channel',
    this.androidChannelName = 'Agent Skill Task',
    this.androidExactAlarm = true,
  });

  /// The drawable resource name put on every notification the intent
  /// schedules on Android, e.g. `'ic_reminder'`. Null uses the default icon
  /// the app's `initialize` stored (`AndroidInitializationSettings`); without
  /// `initialize`, a null crashes the app when the reminder fires, and again
  /// at each boot while it is pending. A name with no drawable fails the call;
  /// the plugin checks it when scheduling. A drawable used only from Dart is
  /// removed by resource shrinking in a release build unless a `keep.xml`
  /// keeps it.
  final String? androidSmallIcon;

  /// The Android notification channel the intent's notifications go to.
  /// Android creates it on first use with [androidChannelName]. When the user
  /// has turned the channel off, the intent refuses.
  final String androidChannelId;

  /// The user-visible name of [androidChannelId] in the system settings.
  /// Android keeps the name it created the channel with; changing this later
  /// does not rename an existing channel.
  final String androidChannelName;

  /// Whether the intent schedules an exact alarm on Android
  /// (`AndroidScheduleMode.exactAllowWhileIdle`). On Android 12 and newer the
  /// app then declares `SCHEDULE_EXACT_ALARM` in its manifest, and on Android
  /// 14 and newer the user must also grant it (it is off by default there;
  /// the app asks with `requestExactAlarmsPermission()`), or the intent
  /// refuses. `USE_EXACT_ALARM` (Android 13+) needs no grant, but Google Play
  /// allows it only for alarm and calendar apps. False schedules
  /// `AndroidScheduleMode.inexactAllowWhileIdle` instead, which needs neither
  /// and may fire up to an hour late on Android 12 and newer (later under
  /// battery saver or Doze). The intent never switches to it on its own.
  final bool androidExactAlarm;
}
