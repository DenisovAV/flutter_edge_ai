import 'package:genkit_hybrid/genkit_hybrid.dart';
import 'package:test/test.dart';

void main() {
  test('RouteDecision is equal by value', () {
    // Not const: identical constants would pass an identity ==.
    RouteDecision only(String t, [String? reason]) =>
        RouteDecision.only(t, reason: reason);
    expect(only('a', 'r'), only('a', 'r'));
    expect(only('a', 'r').hashCode, only('a', 'r').hashCode);
    expect(only('a'), isNot(RouteDecision.prefer('a'.toString())));
    expect(only('a'), isNot(only('b')));
    expect(only('a', 'x'), isNot(only('a', 'y')));
  });

  group('RouteInfo.fromJson', () {
    const base = {
      'router': 'r',
      'policy': 'p',
      'target': 't',
      'model': 'm',
      'source': 'pin',
    };

    test('reads its own output back', () {
      const info = RouteInfo(
        router: 'r',
        policy: 'p',
        target: 't',
        model: 'm',
        source: RouteSource.classifier,
        routeTime: Duration(milliseconds: 3),
        attempts: ['t'],
        classifier: 'c',
        label: 'l',
        score: 0.5,
        margin: 0.25,
        reason: 'why',
        details: {'k': 'v'},
      );
      final back = RouteInfo.fromJson(info.toJson())!;
      expect(back.toJson(), info.toJson());
      expect(back.source, RouteSource.classifier);
    });

    test('drops a field of the wrong type instead of throwing', () {
      final info = RouteInfo.fromJson({
        ...base,
        'rule': 3,
        'score': 'high',
        'attempts': 'x',
        'details': 5,
        'routeMs': 'soon',
      })!;
      expect(info.rule, isNull);
      expect(info.score, isNull);
      expect(info.attempts, isEmpty);
      expect(info.details, isEmpty);
      expect(info.routeTime, Duration.zero);
    });

    test('keeps a source it does not know', () {
      final info = RouteInfo.fromJson({...base, 'source': 'later'})!;
      expect(info.source.name, 'later');
      expect(RouteSource.values, isNot(contains(info.source)));
    });

    test('is null for what is not a route info', () {
      expect(RouteInfo.fromJson('x'), isNull);
      expect(RouteInfo.fromJson({...base, 'router': 1}), isNull);
      expect(RouteInfo.fromJson({...base, 'source': null}), isNull);
    });
  });
}
