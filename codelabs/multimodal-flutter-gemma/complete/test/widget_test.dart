import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/capabilities.dart';
import 'package:edge_ai_quickstart/download_page.dart';
import 'package:edge_ai_quickstart/model.dart';
import 'package:edge_ai_quickstart/wav.dart';

void main() {
  // `isModelInstalled` is keyed by file name. `install()` skips bytes it
  // already has, so a name that drifts from its URL does not re-download — it
  // strands the app on a download screen the gate is never satisfied by. At
  // 2.59 GB that is not a small mistake. Checked for both builds directly —
  // `kIsWeb` is false in this VM test, so `model.url`/`model.fileName` alone
  // would never exercise the web pair.
  test(
    'each build of the model is installed under the file its URL fetches',
    () {
      const model = Models.gemma4;
      expect(model.nativeFileName, model.nativeUrl.split('/').last);
      expect(model.webFileName, model.webUrl.split('/').last);
    },
  );

  // The model half of both questions, for the one checkpoint this app ships.
  // These are what the app ANDs against the platform, so a wrong value here
  // silently disables a modality the weights have.
  test('the model accepts both modalities', () {
    expect(Models.gemma4.supportsImage, isTrue);
    expect(Models.gemma4.supportsAudio, isTrue);
  });

  // The whole point of the type: two independent answers, and a message that
  // names the one that said no. A single bool could not tell these apart.
  group('Capability reports which side refused', () {
    const modelReason = 'the model has no audio encoder';
    const platformReason = 'the platform has no audio input';

    Capability of({required bool byModel, required bool byPlatform}) =>
        Capability(
          what: 'Audio input',
          byModel: byModel,
          byPlatform: byPlatform,
          modelReason: modelReason,
          platformReason: platformReason,
        );

    test('both yes: available, nothing to explain', () {
      final c = of(byModel: true, byPlatform: true);
      expect(c.available, isTrue);
      expect(c.blockedBecause, isNull);
    });

    test('the model said no', () {
      final c = of(byModel: false, byPlatform: true);
      expect(c.available, isFalse);
      expect(c.blockedBecause, modelReason);
    });

    test('the platform said no', () {
      final c = of(byModel: true, byPlatform: false);
      expect(c.available, isFalse);
      expect(c.blockedBecause, platformReason);
    });

    test('both said no — fixing either one alone changes nothing', () {
      final c = of(byModel: false, byPlatform: false);
      expect(c.available, isFalse);
      expect(c.blockedBecause, contains(modelReason));
      expect(c.blockedBecause, contains(platformReason));
    });
  });

  // Forty-four bytes the model has to be able to parse. A wrong length or a
  // wrong sample rate here is not a crash — it is a clip the model hears at
  // the wrong speed, which reads as a bad model.
  test('wavFromPcm16 writes a header the sizes agree with', () {
    final pcm = Uint8List.fromList(List<int>.filled(3200, 0x11));
    final wav = wavFromPcm16(pcm, sampleRate: 16000, channels: 1);
    final view = ByteData.sublistView(wav);

    expect(wav.length, 44 + pcm.length);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    // RIFF size counts everything after its own 8 bytes.
    expect(view.getUint32(4, Endian.little), 36 + pcm.length);
    expect(view.getUint16(20, Endian.little), 1); // uncompressed PCM
    expect(view.getUint16(22, Endian.little), 1); // mono
    expect(view.getUint32(24, Endian.little), 16000);
    expect(view.getUint32(28, Endian.little), 32000); // byte rate
    expect(view.getUint16(32, Endian.little), 2); // block align
    expect(view.getUint16(34, Endian.little), 16); // bits per sample
    expect(view.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);

    // A stream cut mid-sample has no valid encoding: a 16-bit sample is two
    // bytes and a RIFF data chunk is word-aligned. The half sample is dropped,
    // so the header never promises a byte the data does not have.
    final odd = wavFromPcm16(
      Uint8List.fromList(List<int>.filled(3201, 0x11)),
      sampleRate: 16000,
      channels: 1,
    );
    expect(odd.length, 44 + 3200);
    expect(ByteData.sublistView(odd).getUint32(40, Endian.little), 3200);
  });

  testWidgets('the download screen offers the model before any plugin call', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadPage(model: Models.gemma4, onInstalled: () {}),
      ),
    );
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Download model'), findsOneWidget);
  });
}
