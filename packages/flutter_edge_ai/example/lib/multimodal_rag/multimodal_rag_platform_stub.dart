// The web (and any platform without dart:io): no memo files. The Multimodal RAG
// screen hides voice memos there.
import 'dart:typed_data';

/// Whether this is the iOS Simulator.
Future<bool> isIosSimulator() async => false;

Future<String> keepMemoFile(Uint8List wav) => Future.error(
  UnsupportedError('Voice memos are not kept on this platform.'),
);

Future<Uint8List> readMemoFile(String path) =>
    Future.error(UnsupportedError('No memo files on this platform: $path'));

Future<void> forgetMemoFile(String path) async {}

Future<String> temporaryRecordingPath() async => '';

Future<Uint8List> readAndDeleteRecording(String path) =>
    Future.error(UnsupportedError('No recordings on this platform.'));
