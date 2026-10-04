import 'dart:io' as io;

bool get platformIsIOS => io.Platform.isIOS;
bool get platformIsAndroid => io.Platform.isAndroid;
String get systemTempPath => io.Directory.systemTemp.path;

io.File createFile(String path) => io.File(path);
