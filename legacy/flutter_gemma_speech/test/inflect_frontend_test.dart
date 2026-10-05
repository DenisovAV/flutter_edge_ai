// Pure-Dart verification of InflectTextFrontend against the espeak reference.
//
// The frontend reuses Matcha's word->IPA dictionary (word-level phonemes). Its
// output must match espeak's sentence phonemes EXACTLY except for
// context-dependent STRESS placement (espeak re-stresses function words by
// sentence position; a word dictionary can't — the same limitation Matcha
// ships with). So the gate is: phoneme content identical after stripping the
// primary/secondary stress marks (ˈ ˌ).
//
// Fixtures (test/inflect_fixtures/): Matcha's config.json (symbol table) +
// g2p_dict.txt.gz — Inflect reuses them (verified byte-identical symbol set).
import 'dart:io';

import 'package:flutter_gemma_speech/src/model/tts_model_profile.dart';
import 'package:flutter_gemma_speech/src/tts/inflect_text_frontend.dart';
import 'package:flutter_test/flutter_test.dart';

String _stripStress(String s) => s.replaceAll('ˈ', '').replaceAll('ˌ', '');

void main() {
  late InflectTextFrontend fe;
  late Map<int, String> idToSymbol;

  setUpAll(() async {
    final dir = '${Directory.current.path}/test/inflect_fixtures';
    fe = await InflectTextFrontend.load(const TtsModelProfile.inflect(), {
      'config.json': '$dir/config.json',
      'g2p_dict.txt.gz': '$dir/g2p_dict.txt.gz',
    });
    idToSymbol = {for (final e in fe.symbolToId.entries) e.value: e.key};
  });

  String phonemesOf(String text) =>
      _unblanked(fe.encode(text)).map((id) => idToSymbol[id]).join();

  // (text, espeak reference phoneme string) — from the upstream espeak frontend.
  const cases = [
    ('Hello there, how are you today?', 'həlˈoʊ ðˈɛɹ, hˌaʊ ɑːɹ juː tədˈeɪ?'),
    ('Set a reminder for you.', 'sˈɛt ɐ ɹᵻmˈaɪndɚ fɔːɹ juː.'),
  ];

  for (final (text, espeak) in cases) {
    test('frontend phonemes match espeak (modulo stress): "$text"', () {
      final got = phonemesOf(text);
      // ignore: avoid_print
      print('  text:   "$text"\n  got:    "$got"\n  espeak: "$espeak"');
      expect(
        _stripStress(got),
        _stripStress(espeak),
        reason: 'phoneme content differs beyond stress marks',
      );
      expect(
        got.contains('ˈ'),
        isTrue,
        reason: 'stress mark emitted, not dropped',
      );
    });
  }

  test('OOV word routes through the neural G2P resolver; out-of-table symbols '
      'are dropped', () async {
    final dir = '${Directory.current.path}/test/inflect_fixtures';
    final withG2p = await InflectTextFrontend.load(
      const TtsModelProfile.inflect(),
      {
        'config.json': '$dir/config.json',
        'g2p_dict.txt.gz': '$dir/g2p_dict.txt.gz',
      },
      // 'zzz' is out-of-dictionary → this resolver fires. The trailing '5' is
      // not in the 178-symbol table and must be dropped (matching the
      // reference cleaned_text_to_sequence's drop-unknown behavior).
      neuralG2p: (word) => 'zˈɛd5',
    );
    final idToSym = {
      for (final e in withG2p.symbolToId.entries) e.value: e.key,
    };
    // "today" is a dictionary hit (resolver not consulted); "zzz" is OOV.
    final got = _unblanked(
      withG2p.encode('zzz today'),
    ).map((id) => idToSym[id]).join();
    expect(
      got,
      'zˈɛd tədˈeɪ',
      reason: 'resolver IPA (5 dropped) + inter-word space + dict IPA',
    );
  });

  // The reference `say.py` feeds the encoder `[0, id1, 0, id2, …, idN, 0]`.
  // Without the blanks the model still produces audio — about a third as
  // long, and unintelligible — which is why a length-only check never caught
  // it.
  test('ids are interspersed with the VITS blank (id 0)', () {
    final ids = fe.encode('Hello there.');
    expect(ids.length.isOdd, isTrue);
    for (var i = 0; i < ids.length; i += 2) {
      expect(ids[i], 0, reason: 'even position $i must be the blank');
    }
    for (var i = 1; i < ids.length; i += 2) {
      expect(ids[i], isNot(0), reason: 'odd position $i must be a phoneme');
    }
  });

  test('nothing to pronounce stays empty, not a lone blank', () {
    // The worker skips a clause whose ids are empty; `[0]` would reach the
    // encoder instead.
    expect(fe.encode('🙂'), isEmpty);
  });

  test('OOV word with no neural resolver throws (fail-loud)', () {
    // `fe` was loaded WITHOUT a resolver, so an out-of-dictionary word must
    // throw rather than silently produce nothing.
    expect(() => fe.encode('zzz'), throwsA(isA<StateError>()));
  });
}

/// The phoneme ids of a blank-interspersed sequence: every odd position.
List<int> _unblanked(List<int> ids) => [
  for (var i = 1; i < ids.length; i += 2) ids[i],
];
