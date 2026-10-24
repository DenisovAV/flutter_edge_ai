import 'dart:io';

Future<String> createLoraFixture() async {
  final directory = await Directory.systemTemp.createTemp(
    'edge-lora-contract-',
  );
  final file = File('${directory.path}/adapter.gguf');
  await file.writeAsString('test adapter');
  return file.path;
}

Future<void> removeLoraFixture(String path) =>
    File(path).parent.delete(recursive: true);
