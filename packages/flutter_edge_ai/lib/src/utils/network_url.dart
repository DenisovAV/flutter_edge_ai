/// Whether [a] and [b] fetch the same file: compared without their query,
/// fragment and credentials, so a refreshed signed link, or `?download=true`,
/// is the same model — and a version told apart only by the query is not.
///
/// The one rule for this: the install rule's "same source" and the reuse of a
/// download that finished while the app was closed (#873) both use it.
/// Internal to core.
bool sameNetworkUrl(String a, String b) => _withoutQuery(a) == _withoutQuery(b);

String _withoutQuery(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}
