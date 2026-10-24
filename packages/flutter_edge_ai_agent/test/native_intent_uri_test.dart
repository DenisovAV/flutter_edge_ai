import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Records what the intents ask the OS to open, and opens nothing.
class _RecordingLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

Skill _intent(String name) => Skill(
  name: name,
  description: '',
  instructions: '',
  type: SkillType.intent,
);

void main() {
  late _RecordingLauncher launcher;

  setUp(() {
    launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  test('send_email writes spaces as %20 and keeps a plus sign', () async {
    final result = await NativeIntentExecutor().execute(
      _intent('send_email'),
      '{"extra_email": "a@b.c", "extra_subject": "Running late", '
      '"extra_text": "I am late, 1+1 min"}',
    );

    expect(result, isA<TextResult>());
    expect(
      launcher.launched.single,
      'mailto:a@b.c?subject=Running%20late&body=I%20am%20late%2C%201%2B1%20min',
    );
  });

  test('send_text writes spaces as %20', () async {
    await NativeIntentExecutor().execute(
      _intent('send_text'),
      '{"phone_number": "+15550100", "sms_body": "on my way"}',
    );

    expect(launcher.launched.single, 'sms:+15550100?body=on%20my%20way');
  });
}
