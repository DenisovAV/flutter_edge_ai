import 'dart:io';

import 'package:crypto/crypto.dart';

/// The sha256 of the file at [path], hex, read as a stream.
Future<String> fileSha256(String path) async =>
    '${await sha256.bind(File(path).openRead()).first}';
