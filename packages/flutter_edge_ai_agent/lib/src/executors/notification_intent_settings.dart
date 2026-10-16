/// Settings that make `schedule_notification` usable. Passing them is the app
/// saying it has called `FlutterLocalNotificationsPlugin().initialize(...)`
/// itself (its own callbacks, its own default icon) and owns the permission
/// prompts; the agent only checks permissions and schedules.
///
/// The agent never calls `initialize`: a second call would replace the app's
/// callbacks, default icon and presentation options, and the plugin has no way
/// to tell whether it already ran. Without these settings the intent returns
/// an error and makes no plugin call.
///
/// Pass them as `NativeIntentExecutor(notifications: ...)`.
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
  /// the app's `initialize` stored (`AndroidInitializationSettings`). A name
  /// with no drawable fails the call; the plugin checks it when scheduling.
  final String? androidSmallIcon;

  /// The Android notification channel the intent's notifications go to.
  /// Android creates it on first use with [androidChannelName].
  final String androidChannelId;

  /// The user-visible name of [androidChannelId] in the system settings.
  final String androidChannelName;

  /// Whether the intent schedules an exact alarm on Android
  /// (`AndroidScheduleMode.exactAllowWhileIdle`). On Android 12 and newer the
  /// app then needs `SCHEDULE_EXACT_ALARM` granted or `USE_EXACT_ALARM`
  /// declared, or the intent refuses. False schedules
  /// `AndroidScheduleMode.inexactAllowWhileIdle` instead, which needs neither
  /// and may fire minutes late. The intent never switches to it on its own.
  final bool androidExactAlarm;
}
