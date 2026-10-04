import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Device hello', (tester) async {
    expect(1 + 1, equals(2));
    print('[Hello] Device test works!');
  });
}
