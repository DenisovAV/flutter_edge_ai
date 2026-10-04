import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
  });

  tearDown(ServiceRegistry.reset);

  test('dispose resets core services', () async {
    await ServiceRegistry.initialize();
    expect(ServiceRegistry.instance, isNotNull);

    await FlutterEdgeAi.dispose();

    expect(() => ServiceRegistry.instance, throwsStateError);
  });
}
