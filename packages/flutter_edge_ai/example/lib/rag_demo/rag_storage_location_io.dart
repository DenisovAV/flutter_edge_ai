import 'package:path_provider/path_provider.dart';

Future<String> resolveRagStorageLocation(String storageName) async {
  final directory = await getApplicationDocumentsDirectory();
  return '${directory.path}/$storageName';
}
