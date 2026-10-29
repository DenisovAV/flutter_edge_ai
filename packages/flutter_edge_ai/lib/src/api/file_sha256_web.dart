/// The web keeps no local file to hash: the browser stores what it fetched.
Future<String> fileSha256(String path) =>
    throw UnsupportedError('no local files to hash on the web');
