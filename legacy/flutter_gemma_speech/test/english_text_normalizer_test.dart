import 'package:flutter_gemma_speech/src/tts/english_text_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final n = EnglishTextNormalizer({' ', '.', ',', '?'}); // subset for the test
  test('Hello world. -> [Word(hello) Sym( ) Word(world) Sym(.)]', () {
    final t = n.normalize('Hello world.');
    expect(
      t
          .map(
            (x) => x is WordToken
                ? 'W:${x.word}'
                : 'S:${(x as SymbolToken).symbol}',
          )
          .toList(),
      ['W:hello', 'S: ', 'W:world', 'S:.'],
    );
  });
  test('comma becomes a SymbolToken, not stripped', () {
    final t = n.normalize('Sure, ok');
    expect(t.whereType<SymbolToken>().map((s) => s.symbol), contains(','));
  });
  test('splitClauses splits on sentence + clause boundaries', () {
    expect(n.splitClauses('One, two. Three'), ['One,', 'two.', 'Three']);
  });
  test('splitClauses keeps comma-grouped numbers intact', () {
    expect(n.splitClauses('We shipped 1,234 items'), [
      'We shipped 1,234 items',
    ]);
    expect(n.splitClauses('First, 1,234,567 units. Done'), [
      'First,',
      '1,234,567 units.',
      'Done',
    ]);
  });
  test('splitClauses keeps decimals intact', () {
    expect(n.splitClauses('Pi is 3.14, roughly. Yes'), [
      'Pi is 3.14,',
      'roughly.',
      'Yes',
    ]);
  });
  test('integer expands to words', () {
    final t = EnglishTextNormalizer({' '}).normalize('3 cats');
    expect((t.first as WordToken).word, 'three');
  });
  test('year expands', () {
    final w = EnglishTextNormalizer({
      ' ',
    }).normalize('2023').whereType<WordToken>().map((x) => x.word).join(' ');
    expect(w, 'twenty twenty three');
  });
  test('year 2005 keeps the "oh" (not "twenty five")', () {
    final w = EnglishTextNormalizer({
      ' ',
    }).normalize('2005').whereType<WordToken>().map((x) => x.word).join(' ');
    expect(w, contains('oh'));
    expect(w, 'twenty oh five');
  });
  test('year 2000 reads as a plain number, not "twenty zero"', () {
    final w = EnglishTextNormalizer({
      ' ',
    }).normalize('2000').whereType<WordToken>().map((x) => x.word).join(' ');
    expect(w, 'two thousand');
  });
  test('acronym GPU spells out', () {
    final w = EnglishTextNormalizer({
      ' ',
    }).normalize('GPU').whereType<WordToken>().map((x) => x.word).join(' ');
    expect(w, 'g p u');
  });
  test('markdown bold stripped to inner word', () {
    final w = EnglishTextNormalizer({
      ' ',
    }).normalize('**Save**').whereType<WordToken>().map((x) => x.word).join();
    expect(w, 'save');
  });
  test('large number (>=1M) is digit-spelled, not a RangeError crash', () {
    final w = EnglishTextNormalizer({' '})
        .normalize('2,000,000 users')
        .whereType<WordToken>()
        .map((x) => x.word)
        .join(' ');
    expect(w, 'two zero zero zero zero zero zero users');
  });
  test('backtick-wrapped content is kept, not deleted', () {
    final w = EnglishTextNormalizer({' '})
        .normalize('the `answer` is `42`')
        .whereType<WordToken>()
        .map((x) => x.word)
        .toList();
    // Inner content survives: "answer" stays a word, and "42" expands to
    // its number words instead of vanishing.
    expect(w, contains('answer'));
    expect(w, isNot(contains('')));
    expect(w, ['the', 'answer', 'is', 'forty', 'two']);
  });
}
