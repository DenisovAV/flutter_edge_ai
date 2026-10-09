import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  group('ComponentRegistry', () {
    test('the prompt lists what the model may present and nothing app-owned', () {
      final text = ComponentRegistry.describeForPrompt();
      for (final c in ComponentRegistry.forModel) {
        expect(text, contains('- ${c.id}:'));
      }
      expect(text, isNot(contains(ComponentRegistry.searchFilters.id)));
      expect(ComponentRegistry.forModel, isNot(contains(ComponentRegistry.searchFilters)));
      expect(ComponentRegistry.all, contains(ComponentRegistry.searchFilters));
    });

    test('the registry lists cannot be changed from outside', () {
      expect(ComponentRegistry.all.clear, throwsUnsupportedError);
      expect(ComponentRegistry.forModel.clear, throwsUnsupportedError);
    });

    test('byId finds every component and nothing else', () {
      for (final c in ComponentRegistry.all) {
        expect(ComponentRegistry.byId(c.id), same(c));
      }
      expect(ComponentRegistry.byId('pie_chart'), isNull);
    });

    test('limits in the prompt text match the validator', () {
      expect(ComponentRegistry.choice.description, contains('$minOptions–$maxChoiceOptions'));
      expect(
        ComponentRegistry.multiChoice.description,
        contains('$minOptions–$maxMultiChoiceOptions'),
      );
      expect(ComponentRegistry.inputForm.description, contains('1–$maxFormFields'));
    });
  });

  group('PresentRequest.validate', () {
    test('valid request uses the component default surface', () {
      final v = PresentRequest.validate({
        'component': 'payment_breakdown',
        'result_id': 'r1',
      }, resultTool: 'estimate_payment');
      expect(v.errors, isEmpty);
      expect(v.request!.surface, SurfaceState.fullscreen);
    });

    test('an unknown component is told what the model may choose from', () {
      final v = PresentRequest.validate({
        'component': 'pie_chart',
        'result_id': 'r1',
      }, resultTool: 'estimate_payment');
      expect(v.request, isNull);
      expect(v.errors.single, contains('payment_summary'));
      expect(v.errors.single, isNot(contains('search_filters')));
    });

    test('rejects mismatched tools, missing results and a collapsed surface', () {
      expect(
        PresentRequest.validate({
          'component': 'ownership_cost',
          'result_id': 'r1',
        }, resultTool: 'estimate_payment').errors.single,
        contains('cannot render'),
      );
      expect(
        PresentRequest.validate({
          'component': 'payment_summary',
          'result_id': 'r1',
          'surface': 'collapsed',
        }, resultTool: 'estimate_payment').errors.single,
        contains('surface'),
      );
      expect(
        PresentRequest.validate({
          'component': 'payment_summary',
          'result_id': 'r9',
        }, resultTool: null).errors.single,
        contains('does not match'),
      );
      expect(
        PresentRequest.validate({'component': 'payment_summary'}, resultTool: null).errors.single,
        contains('result_id is required'),
      );
    });

    test('choice needs props, not a result', () {
      final ok = PresentRequest.validate({
        'component': 'choice',
        'props': {
          'question': 'How are you shopping today?',
          'options': [
            {'id': 'browsing', 'label': 'Just looking'},
            {'id': 'practical', 'label': 'Practical options'},
            {'id': 'buying', 'label': 'Buying now'},
          ],
        },
      }, resultTool: null);
      expect(ok.errors, isEmpty);
      expect(ok.request!.resultId, isNull);
      expect(ok.request!.props['options'] as List, hasLength(3));

      final bad = PresentRequest.validate({
        'component': 'choice',
        'props': {
          'question': 'x',
          'options': [
            {'id': 'a', 'label': 'only one'},
          ],
        },
      }, resultTool: null);
      expect(bad.errors.single, contains('at least $minOptions'));
    });

    test('too many options are trimmed on a copy; the caller keeps its list', () {
      final options = [
        for (var i = 0; i < 9; i++)
          {'id': 'o$i', 'label': 'option number $i with a very long label that goes on and on'},
      ];
      final props = {'question': 'Which?', 'options': options};
      final v = PresentRequest.validate({'component': 'choice', 'props': props}, resultTool: null);
      expect(v.errors, isEmpty);
      expect((v.request!.props['options'] as List).length, maxChoiceOptions);
      expect(options, hasLength(9));
      expect(props['options'], same(options));

      final multi = PresentRequest.validate({
        'component': 'multi_choice',
        'props': props,
      }, resultTool: null);
      expect((multi.request!.props['options'] as List).length, maxMultiChoiceOptions);
    });

    test('a result component carries no props even when the model sends some', () {
      final v = PresentRequest.validate({
        'component': 'payment_summary',
        'result_id': 'r1',
        'props': {'question': 'ignored'},
      }, resultTool: 'estimate_payment');
      expect(v.errors, isEmpty);
      expect(v.request!.props, isEmpty);
      expect(v.request!.resultId, 'r1');
    });

    test('input_form validates field types and the field count', () {
      final v = PresentRequest.validate({
        'component': 'input_form',
        'props': {
          'title': 'Your trade-in',
          'fields': [
            {'id': 'value', 'label': 'What is it worth?', 'type': 'currency'},
            {'id': 'payoff', 'label': 'What do you owe?', 'type': 'currency'},
            {
              'id': 'state',
              'label': 'State',
              'type': 'select',
              'options': ['NC', 'SC'],
            },
          ],
        },
      }, resultTool: null);
      expect(v.errors, isEmpty);
      final bad = PresentRequest.validate({
        'component': 'input_form',
        'props': {
          'fields': [
            {'id': 'x', 'label': 'x', 'type': 'date'},
          ],
        },
      }, resultTool: null);
      expect(bad.errors.single, contains('type must be one of'));
      final tooMany = PresentRequest.validate({
        'component': 'input_form',
        'props': {
          'fields': [
            for (var i = 0; i <= maxFormFields; i++) {'id': 'f$i', 'label': 'f', 'type': 'text'},
          ],
        },
      }, resultTool: null);
      expect(tooMany.errors.single, contains('1 to $maxFormFields'));
    });

    test('highlights are field names and are carried through', () {
      final v = PresentRequest.validate({
        'component': 'payment_summary',
        'result_id': 'r1',
        'highlights': ['monthlyPayment'],
      }, resultTool: 'estimate_payment');
      expect(v.request!.highlights, ['monthlyPayment']);
      final bad = PresentRequest.validate({
        'component': 'payment_summary',
        'result_id': 'r1',
        'highlights': [1],
      }, resultTool: 'estimate_payment');
      expect(bad.errors.single, contains('highlights'));
    });
  });
}
