import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Whether this is the iOS Simulator, which has no GPU for LiteRT-LM (Metal
/// there caps one allocation at 256 MB). Measured: neither the SIMULATOR_*
/// variables nor HOME reach a simulator app's Platform.environment under
/// `flutter test`, so the app's own documents directory decides — on the
/// simulator it lies inside CoreSimulator's device directory on the Mac.
Future<bool> isIosSimulator() async {
  if (!Platform.isIOS) return false;
  if (Platform.environment.containsKey('SIMULATOR_DEVICE_NAME')) return true;
  final documents = await getApplicationDocumentsDirectory();
  return documents.path.contains('/CoreSimulator/Devices/');
}

const _memoDirectory = 'knowledge_memos';
int _counter = 0;

Future<Directory> _memos() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory(
    '${documents.path}${Platform.pathSeparator}$_memoDirectory',
  ).create(recursive: true);
}

/// Keeps a recorded memo in `<documents>/knowledge_memos/`; returns its path.
Future<String> keepMemoFile(Uint8List wav) async {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final file = File(
    '${(await _memos()).path}${Platform.pathSeparator}'
    'memo-$stamp-${_counter++}.wav',
  );
  await file.writeAsBytes(wav, flush: true);
  return file.path;
}

Future<Uint8List> readMemoFile(String path) => File(path).readAsBytes();

/// Deletes a memo [keepMemoFile] kept; leaves any other path alone.
Future<void> forgetMemoFile(String path) async {
  final file = File(path);
  if (file.parent.path != (await _memos()).path) return; // not ours
  if (await file.exists()) await file.delete();
}

/// Where the recorder writes before the memo is kept.
Future<String> temporaryRecordingPath() async =>
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}'
    'knowledge_recording.wav';

Future<Uint8List> readAndDeleteRecording(String path) async {
  final file = File(path);
  final bytes = await file.readAsBytes();
  await file.delete();
  return bytes;
}
