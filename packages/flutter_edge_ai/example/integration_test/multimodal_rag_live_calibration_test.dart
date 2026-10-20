// Measures what Live and "Ask by voice" rely on, with the real models:
//
// 1. Meeting audio → library: every utterance window of the bundled meeting is
//    embedded by EmbeddingGemma 2 (740M) as an AUDIO query and searched
//    against the notes, photos and memos (multimodal_rag_index.dart, lift over each
//    kind's median). Prints each window's top three with lift and cosine,
//    and the margin of the best over the runner-up: the surfacing threshold
//    is calibrated from these numbers.
// 2. Spoken question → library: the spoken "How much was the airport taxi?"
//    (and other phrasings, both voices) as audio queries; the receipt photo
//    should rank first.
// 3. Question detection: Gemma 4 hears each window with each candidate
//    prompt; prints the reply and how long it took.
//
// Needs the audio from generate_knowledge_memos.dart in <documents>/
// knowledge_memos (macOS: run that first). Models: multimodal_rag_models.dart.
//   flutter test integration_test/multimodal_rag_live_calibration_test.dart -d macos …

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/image_search/photo_preparation.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_app_dependencies.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_audio.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_dependencies.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_index.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_item.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_library.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_live.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_prompt.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_ranking.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/utils/audio_converter.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'multimodal_rag_models.dart';

const _prompts = <String, String>{'direct': kLiveListenPrompt};

/// `answers`: only the answer comparison (it needs no meeting audio files,
/// so it runs on a phone or the iOS Simulator too).
const _mode = String.fromEnvironment('MULTIMODAL_RAG_CALIBRATE');

/// System instructions to compare for "How much was the airport taxi?".
const _systems = <String, String>{
  'current': kMultimodalRagSystemInstruction,
  'total':
      'You answer questions about the user\'s own notes, voice memos and '
      'photos, using only the numbered sources; an attached image or '
      'recording is one of them. When asked what something cost, read the '
      'TOTAL line of the receipt, not a single item such as a fee. After '
      'each fact, cite its source number in square brackets, like [1]. '
      'Answer in one short sentence.',
};

void _log(String line) {
  // ignore: avoid_print
  print('[calibrate] $line');
}

Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

String _top(List<RankedHit> hits) => [
  for (final h in hits.take(3))
    '${h.id} lift ${h.lift.toStringAsFixed(3)} cos ${h.similarity.toStringAsFixed(3)}',
].join(' | ');

String _margin(List<RankedHit> hits) =>
    hits.length < 2 ? '-' : (hits[0].lift - hits[1].lift).toStringAsFixed(3);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('calibrates Live and Ask by voice', (tester) async {
    await ensureMultimodalRagModels(log: _log);
    const model = catalog.EmbeddingModel.embeddingGemma2TextVisionAudio740m;
    final info = MultimodalRagEmbedderInfo(
      name: model.displayName,
      textProfileId: model.ragProfileId,
      kinds: MultimodalRagKind.values.toSet(),
    );
    final directory = await Directory(
      '${(await getTemporaryDirectory()).path}/knowledge_calibration_'
      '${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final index = await MultimodalRagIndex.open(
      kinds: info.kinds,
      embedderFor: (kind) => FlutterEdgeAiActiveEmbedder(
        profileId: multimodalRagProfileId(kind, info),
        supportImage: true,
        supportAudio: true,
      ),
      openIndex: (kind, embedder) => exampleRag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: '${directory.path}/${kind.name}.db',
          documents: kind.modality,
        ),
        embedder: embedder,
      ),
    );
    try {
      for (final item in MultimodalRagLibrary.seeded().items) {
        switch (item) {
          case NoteItem():
            await index.addNote(item);
          case PhotoItem(:final reference):
            await index.addPhoto(
              item,
              (await preparePhotoForEmbedding(
                await _asset(reference.substring('asset:'.length)),
              )).bytes,
            );
          case MemoItem(:final reference):
            await index.addMemo(
              item,
              await _asset(reference.substring('asset:'.length)),
            );
        }
      }
      _log('library indexed: ${index.counts}');

      final wavs = <Uint8List>[];
      if (_mode != 'answers') {
        // 1. Meeting windows as audio queries.
        final meeting = pcm16kMonoFromWav(
          await _asset('assets/knowledge/meeting.wav'),
        );
        final windower = MeetingWindower();
        final windows = <({Duration start, Uint8List pcm})>[];
        for (var i = 0; i < meeting.length; i += 3200) {
          windows.addAll(
            windower.add(
              Uint8List.sublistView(
                meeting,
                i,
                (i + 3200).clamp(0, meeting.length),
              ),
            ),
          );
        }
        if (windower.flush() case final tail?) windows.add(tail);
        for (final (i, w) in windows.indexed) {
          final wav = AudioConverter.pcmToWav(w.pcm);
          wavs.add(wav);
          final watch = Stopwatch()..start();
          final hits = await index.searchBy(
            EmbeddingInput.audio(wav),
            minLift: -1,
          );
          _log(
            'window $i ${w.start.inMilliseconds}–'
            '${(w.start + pcmDuration(w.pcm)).inMilliseconds} ms '
            '(${watch.elapsedMilliseconds} ms, embed '
            '${index.lastQueryEmbedding.inMilliseconds}): margin '
            '${_margin(hits)} · ${_top(hits)}',
          );
        }

        // 2. Spoken questions.
        final memos = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/knowledge_memos',
        );
        final questions =
            memos
                .listSync()
                .whereType<File>()
                .where((f) => f.path.split('/').last.startsWith('question_'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        for (final file in questions) {
          final wav = AudioConverter.pcmToWav(
            pcm16kMonoFromWav(await file.readAsBytes()),
          );
          final hits = await index.searchBy(
            EmbeddingInput.audio(wav),
            minLift: -1,
          );
          _log(
            'spoken ${file.path.split('/').last}: margin ${_margin(hits)} · '
            '${_top(hits)}',
          );
        }
        for (final text in [
          'How much was the airport taxi?',
          'Wait, how much did the airport taxi cost?',
        ]) {
          final hits = await index.searchBy(
            EmbeddingInput.text(text),
            minLift: -1,
          );
          _log('typed "$text": margin ${_margin(hits)} · ${_top(hits)}');
        }
      }

      final answerer = multimodalRagAppDependencies().answerer;
      _log('language model on ${await answerer.warmUp()}');

      // 3. Question detection, per prompt.
      if (_mode != 'answers') {
        for (final MapEntry(key: name, value: prompt) in _prompts.entries) {
          for (final (i, wav) in wavs.indexed) {
            final watch = Stopwatch()..start();
            final reply = StringBuffer();
            await for (final chunk in answerer.answer(
              systemInstruction: kLiveListenInstruction,
              prompt: prompt,
              audio: wav,
              maxOutputTokens: 60,
            )) {
              reply.write(chunk);
            }
            _log(
              'prompt $name window $i (${watch.elapsedMilliseconds} ms): '
              '${reply.toString().trim().replaceAll('\n', ' / ')} → '
              '${parseLiveQuestion(reply.toString())}',
            );
          }
        }
      }

      // The question, typed and spoken, answered from the receipt and the
      // trip note, under each system instruction.
      final receipt = (await preparePhotoForEmbedding(
        await _asset('assets/knowledge/photos/taxi_receipt.png'),
      )).bytes;
      final spokenWav = AudioConverter.pcmToWav(
        pcm16kMonoFromWav(await _asset('assets/knowledge/question.wav')),
      );
      final library = MultimodalRagLibrary.seeded();
      for (final MapEntry(key: name, value: system) in _systems.entries) {
        for (final (label, question, audio) in [
          ('typed', 'How much was the airport taxi?', null),
          ('spoken', 'Spoken question', spokenWav),
        ]) {
          final watch = Stopwatch()..start();
          Duration? first;
          final reply = StringBuffer();
          await for (final chunk in answerer.answer(
            systemInstruction: system,
            prompt: buildMultimodalRagPrompt(question, [
              (number: 1, item: library.byId('photo-0412')!, attached: true),
              (number: 2, item: library.byId('note-london')!, attached: false),
            ], spoken: audio != null),
            images: [receipt],
            audio: audio,
          )) {
            first ??= watch.elapsed;
            reply.write(chunk);
          }
          _log(
            'answer $name/$label: first words ${first?.inMilliseconds} ms, '
            '${watch.elapsedMilliseconds} ms: ${reply.toString().trim()}',
          );
        }
      }
    } finally {
      await index.dispose();
    }
  });
}
