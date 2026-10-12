import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Keeps App Nap off for the whole process lifetime. The example's integration
  // tests (`flutter test integration_test/... -d macos`) run the app in the
  // background, and after about a minute App Nap throttles on-device model work
  // 3-8x (an image embedding goes from 0.35 s to 2-7 s). An `NSAppSleepDisabled`
  // key in Info.plist is not honored, so the opt-out has to be made in code.
  // `.userInitiatedAllowingIdleSystemSleep` disables App Nap and timer throttling
  // but still lets the Mac idle-sleep. An app that works in the background should
  // hold an activity only while the work runs; the example holds one for its
  // lifetime because it is a test harness and a demo.
  private var appNapActivity: NSObjectProtocol?

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    appNapActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "flutter_edge_ai example: on-device model inference and integration tests"
    )
  }

  // FlutterAppDelegate does not implement applicationWillTerminate(_:), so there
  // is no super call (it would be an unrecognized selector at runtime).
  override func applicationWillTerminate(_ notification: Notification) {
    if let activity = appNapActivity {
      ProcessInfo.processInfo.endActivity(activity)
      appNapActivity = nil
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
