import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SecretStore', () {
    test('set / get / has by skill name', () {
      final store = SecretStore();
      expect(store.has('weather'), isFalse);
      expect(store.get('weather'), isNull);

      store.set('weather', 'sk-123');
      expect(store.get('weather'), 'sk-123');
      expect(store.has('weather'), isTrue);
    });

    test('empty secret clears the entry (set/get/has all agree)', () {
      final store = SecretStore()..set('x', '');
      expect(store.has('x'), isFalse);
      expect(store.get('x'), isNull);
    });

    test('setting an empty secret removes a previously stored one', () {
      final store = SecretStore()..set('x', 'sk-1');
      expect(store.has('x'), isTrue);
      store.set('x', '');
      expect(store.has('x'), isFalse);
      expect(store.get('x'), isNull);
    });

    test('set replaces existing value', () {
      final store = SecretStore()
        ..set('x', 'a')
        ..set('x', 'b');
      expect(store.get('x'), 'b');
    });

    test('remove and clear', () {
      final store = SecretStore()
        ..set('a', '1')
        ..set('b', '2');

      store.remove('a');
      expect(store.get('a'), isNull);
      expect(store.get('b'), '2');

      store.clear();
      expect(store.get('b'), isNull);
    });
  });
}
