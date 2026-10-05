import 'package:flutter_gemma_speech/src/voice/clause_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('emits a clause at a sentence boundary', () {
    final s = ClauseSplitter();
    expect(s.feed('Hello world. '), ['Hello world. ']);
    expect(s.flush(), '');
  });

  test('buffers an incomplete clause across tokens', () {
    final s = ClauseSplitter();
    expect(s.feed('Hello '), isEmpty);
    expect(s.feed('world'), isEmpty);
    expect(s.feed('. rest here'), ['Hello world. ']);
    expect(s.flush(), 'rest here');
  });

  test('short fragments merge forward into the next clause (minLength)', () {
    final s = ClauseSplitter();
    expect(s.feed('Hi. '), isEmpty); // "Hi." trimmed=3 < 8 → merge
    expect(s.feed('There you go. '), ['Hi. There you go. ']);
  });

  test('does not split inside a decimal (no trailing whitespace)', () {
    final s = ClauseSplitter();
    // 3.14's dot is followed by a digit, not whitespace → not a boundary.
    expect(s.feed('It is 3.14 today. '), ['It is 3.14 today. ']);
  });

  test('an abbreviation stays merged (Dr. under minLength)', () {
    final s = ClauseSplitter();
    expect(s.feed('Dr. Smith arrived. '), ['Dr. Smith arrived. ']);
  });

  test('splits on a newline', () {
    final s = ClauseSplitter();
    expect(s.feed('First line here\nSecond'), ['First line here\n']);
    expect(s.flush(), 'Second');
  });

  test('multiple complete clauses in one feed', () {
    final s = ClauseSplitter();
    expect(s.feed('One sentence here. Two sentence here! '), [
      'One sentence here. ',
      'Two sentence here! ',
    ]);
  });

  test('flush returns the unterminated tail', () {
    final s = ClauseSplitter();
    expect(s.feed('The end is here'), isEmpty);
    expect(s.flush(), 'The end is here');
  });

  test('flush is empty after a clean boundary', () {
    final s = ClauseSplitter();
    s.feed('All finished now. ');
    expect(s.flush(), '');
  });

  test('collapses multiple enders (?! )', () {
    final s = ClauseSplitter();
    expect(s.feed('Really now?! Yes indeed. '), [
      'Really now?! ',
      'Yes indeed. ',
    ]);
  });
}
