// The Multimodal RAG screen's pure parts: ranking across kinds by lift, snippet
// highlighting, cutting audio at its quietest moment, Live's utterance
// windows and question parsing, the prompt and its citations, and the saved
// library.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_audio.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_item.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_library.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_live.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_prompt.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_ranking.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_seed.dart';
import 'package:flutter_edge_ai_example/utils/audio_converter.dart';
import 'package:flutter_test/flutter_test.dart';

List<ScoredDocument> _docs(String prefix, List<double> scores) => [
  for (final (i, s) in scores.indexed) (id: '$prefix$i', similarity: s),
];

/// 16 kHz mono PCM16: each span [ms] long at [amplitude] (0 is silence).
Uint8List speech(List<(int ms, int amplitude)> spans) {
  final samples = <int>[];
  for (final (ms, amplitude) in spans) {
    for (var i = 0; i < ms * 16; i++) {
      samples.add(i.isEven ? amplitude : -amplitude);
    }
  }
  final bytes = ByteData(samples.length * 2);
  for (final (i, s) in samples.indexed) {
    bytes.setInt16(i * 2, s, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  group('rankAcrossKinds', () {
    test('ranks by lift over each kind\'s median, not by raw cosine', () {
      // Measured shape: memos sit higher across the board than notes.
      final ranked = rankAcrossKinds({
        MultimodalRagKind.note: _docs('n', [0.52, 0.55, 0.56, 0.57, 0.77]),
        MultimodalRagKind.memo: _docs('m', [0.62, 0.64, 0.66, 0.68, 0.72]),
      });
      // n4 lifts 0.21; m4 has the higher cosine but lifts only 0.06.
      expect(ranked.map((h) => h.id), ['n4', 'm4']);
      expect(ranked.first.lift, closeTo(0.21, 1e-9));
      expect(ranked.first.strength, 1.0);
      expect(ranked.last.strength, closeTo(0.06 / kFullLift, 1e-9));
    });

    test('leaves out what does not stand out, and keeps at most limit', () {
      final flat = rankAcrossKinds({
        MultimodalRagKind.photo: _docs('p', [0.58, 0.59, 0.6, 0.61]),
      });
      expect(flat, isEmpty);
      final many = rankAcrossKinds({
        MultimodalRagKind.note: _docs('n', [0.5, 0.5, 0.5, 0.9, 0.9, 0.9]),
      }, limit: 2);
      expect(many, hasLength(2));
    });

    test('a kind with too few documents is measured against its measured '
        'baseline', () {
      final ranked = rankAcrossKinds({
        MultimodalRagKind.memo: _docs('m', [0.72, 0.66]),
      });
      expect(ranked.single.id, 'm0');
      expect(
        ranked.single.lift,
        closeTo(0.72 - kFallbackBaseline[MultimodalRagKind.memo]!, 1e-9),
      );
    });
  });

  group('highlight', () {
    String marked(String text, String query) => [
      for (final part in highlight(text, query))
        if (part.match) part.text,
    ].join(',');

    test('marks the query\'s words by stem, not stop words', () {
      expect(
        marked('My flight to London is delayed.', 'my flight is delays'),
        'flight,delayed',
      );
      expect(marked('Call Mom on Sunday', 'what did I say'), '');
    });

    test('keeps every character, in order', () {
      const text = 'The kitchen lights keep flickering.';
      expect(
        highlight(text, 'flickering lights').map((p) => p.text).join(),
        text,
      );
    });
  });

  group('splitForSpeechWindow', () {
    test('a memo inside the window stays whole', () {
      final pcm = speech([(4000, 1000)]);
      expect(splitForSpeechWindow(pcm, window: const Duration(seconds: 5)), [
        pcm,
      ]);
    });

    test('a longer memo is cut at its quietest moment before each window '
        'ends, losing nothing', () {
      // 4.2 s of speech, a 300 ms pause, then 4 s more.
      final pcm = speech([(4200, 3000), (300, 0), (4000, 3000)]);
      final pieces = splitForSpeechWindow(
        pcm,
        window: const Duration(seconds: 5),
      );
      expect(pieces, hasLength(2));
      expect(pieces.fold<int>(0, (n, p) => n + p.length), pcm.length);
      final firstMs = pieces.first.length ~/ 32;
      expect(firstMs, inInclusiveRange(4200, 4500), reason: 'in the pause');
      for (final piece in pieces) {
        expect(piece.length, lessThanOrEqualTo(5 * kPcmBytesPerSecond));
        expect(piece.length.isEven, isTrue);
      }
    });

    test('reads a WAV at another rate as 16 kHz mono', () {
      final wav = AudioConverter.pcmToWav(
        Uint8List(44100 * 2),
        sampleRate: 44100,
      );
      expect(
        pcmDuration(pcm16kMonoFromWav(wav)).inMilliseconds,
        closeTo(1000, 2),
      );
    });
  });

  group('MeetingWindower', () {
    List<({Duration start, Uint8List pcm})> feed(
      MeetingWindower windower,
      Uint8List pcm, {
      int chunk = 3200,
    }) => [
      for (var i = 0; i < pcm.length; i += chunk)
        ...windower.add(
          Uint8List.sublistView(pcm, i, math.min(i + chunk, pcm.length)),
        ),
    ];

    test('cuts at the first pause once a window holds enough speech, and '
        'leaves leading silence out', () {
      final windower = MeetingWindower();
      final windows = feed(
        windower,
        speech([
          (500, 0),
          (2000, 3000),
          (400, 0),
          (1000, 3000),
          (100, 0), // too short a pause
          (1200, 3000),
          (400, 0),
        ]),
      );
      expect(windows, hasLength(2));
      expect(windows[0].start, const Duration(milliseconds: 500));
      expect(
        pcmDuration(windows[0].pcm).inMilliseconds,
        inInclusiveRange(2280, 2300),
        reason: 'the speech and the pause that ended it',
      );
      // The rest of the pause is the next window's leading silence.
      expect(windows[1].start, const Duration(milliseconds: 2900));
      expect(
        pcmDuration(windows[1].pcm).inMilliseconds,
        greaterThan(2300),
        reason: 'a 100 ms pause does not end a window',
      );
      expect(windower.heard, const Duration(milliseconds: 5600));
    });

    test('speech without a pause is cut at the longest window', () {
      final windower = MeetingWindower();
      final windows = feed(windower, speech([(9000, 3000)]));
      expect(windows, hasLength(1));
      expect(pcmDuration(windows.single.pcm), kLiveMaxWindow);
      final tail = windower.flush();
      expect(pcmDuration(tail!.pcm), const Duration(seconds: 3));
      expect(tail.start, kLiveMaxWindow);
    });

    test('a tail too short to hear is dropped', () {
      final windower = MeetingWindower();
      expect(feed(windower, speech([(500, 3000)])), isEmpty);
      expect(windower.flush(), isNull);
    });

    test('chunk size does not change the windows', () {
      final pcm = speech([
        (300, 0),
        (2500, 3000),
        (500, 0),
        (2100, 2000),
        (300, 0),
      ]);
      String shape(int chunk) => [
        for (final w in feed(MeetingWindower(), pcm, chunk: chunk))
          '${w.start.inMilliseconds}+${pcmDuration(w.pcm).inMilliseconds}',
      ].join(' ');
      expect(shape(640), shape(3200));
      expect(shape(1000), shape(3200));
    });

    test('pcmLevel is 0 for silence and rises with loudness', () {
      expect(pcmLevel(speech([(100, 0)])), 0);
      expect(
        pcmLevel(speech([(100, 3000)])),
        greaterThan(pcmLevel(speech([(100, 300)]))),
      );
      expect(pcmLevel(speech([(100, 32000)])), 1.0);
    });
  });

  group('parseLiveQuestion', () {
    test('reads the question Gemma 4 names', () {
      expect(
        parseLiveQuestion('QUESTION: How much did the airport taxi cost?'),
        'How much did the airport taxi cost?',
      );
      expect(
        parseLiveQuestion('question:  Wait, when is the dentist\nmore'),
        'Wait, when is the dentist',
      );
    });

    test('NONE, other replies and statements named as questions are none', () {
      expect(parseLiveQuestion('NONE'), isNull);
      expect(parseLiveQuestion('QUESTION: NONE'), isNull);
      expect(parseLiveQuestion('Okay, quick sync before the weekend.'), isNull);
      expect(
        parseLiveQuestion(
          'QUESTION: Also, the office kitchen lights keep flickering again.',
        ),
        isNull,
      );
    });
  });

  group('prompt', () {
    const note = NoteItem(id: 'n', title: 'London trip', body: 'Terminal 5.');
    const photo = PhotoItem(id: 'p', title: 'IMG_1', reference: 'asset:x');
    const memo = MemoItem(
      id: 'm',
      title: 'Voice memo 1',
      reference: 'asset:y',
      duration: Duration(seconds: 4),
    );

    test('numbers the sources and says which photo and memo are attached', () {
      final prompt = buildMultimodalRagPrompt(' When? ', [
        (number: 1, item: photo, attached: true),
        (number: 2, item: note, attached: false),
        (number: 3, item: memo, attached: true),
        (number: 4, item: photo, attached: false),
        (number: 5, item: memo, attached: false),
      ]);
      expect(
        prompt,
        'Sources:\n'
        '[1] Photo: the attached image\n'
        '[2] Note "London trip": Terminal 5.\n'
        '[3] Voice memo: the attached recording\n'
        '[4] Photo (not shown to you)\n'
        '[5] Voice memo (not played to you)\n'
        '\n'
        'Question: When?',
      );
    });

    test('a spoken question is the recording, never written out', () {
      final prompt = buildMultimodalRagPrompt('Spoken question', [
        (number: 1, item: photo, attached: true),
      ], spoken: true);
      expect(prompt, isNot(contains('Spoken question')));
      expect(prompt, contains('it is the attached recording'));
    });

    test('reads the citations of an answer', () {
      expect(citedSources('It was 26.50 [1]. Covered [2, 3][1].'), [1, 2, 3]);
      expect(citedSources('No sources.'), isEmpty);
    });
  });

  group('library', () {
    test('saves the user\'s items and what is indexed per embedding '
        'space', () {
      final library = MultimodalRagLibrary.seeded()
        ..add(const NoteItem(id: 'note-1', title: 'Mine', body: 'text'))
        ..markIndexed('space-a', 'note-1', const Duration(milliseconds: 40))
        ..markIndexed('space-a', 'memo-mom', const Duration(milliseconds: 160));
      final restored = MultimodalRagLibrary.decode(library.encode());
      expect(restored.items, hasLength(library.items.length));
      expect((restored.byId('note-1')! as NoteItem).body, 'text');
      expect(
        restored.indexedIn('space-a')['memo-mom'],
        const Duration(milliseconds: 160),
      );
      expect(restored.indexedIn('space-b'), isEmpty);
      restored.forgetIndexed('space-a', kind: MultimodalRagKind.memo);
      expect(restored.indexedIn('space-a').keys, ['note-1']);
    });

    test('starts with every sample', () {
      expect(
        MultimodalRagLibrary.seeded().items,
        hasLength(kSeedNotes.length + kSeedPhotos.length + kSeedMemos.length),
      );
    });

    test('a corrupt save is reported', () {
      expect(
        () => MultimodalRagLibrary.decode('[1, 2]'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
