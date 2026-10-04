import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('minimal: 1+1', (tester) async {
    expect(1 + 1, 2);
    print('MINIMAL TEST PASSED');
  });
}
