bool get platformIsIOS => false;
bool get platformIsAndroid => false;
String get systemTempPath => '';

Never createFile(String path) =>
    throw UnsupportedError('File is not available on web');
