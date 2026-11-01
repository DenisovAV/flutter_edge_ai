import 'dart:convert';

import 'package:integration_test/integration_test_driver.dart';

/// Prints the replies the test recorded: `flutter drive` shows nothing the
/// page prints, and a green run over a test that never ran looks the same.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    // ignore: avoid_print
    print('REPLIES ${jsonEncode(data)}');
  },
);
