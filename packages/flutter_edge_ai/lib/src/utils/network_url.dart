/// Whether [a] and [b] fetch the same file as the install rule sees it:
/// compared without their query, fragment and credentials, so a refreshed
/// signed link, or `?download=true`, is the same model — and a version told
/// apart only by the query is not.
///
/// Internal to core.
bool sameNetworkUrl(String a, String b) => _withoutQuery(a) == _withoutQuery(b);

/// Whether a file downloaded from [downloaded] may stand for one requested
/// from [requested] (#873).
///
/// Stricter than [sameNetworkUrl]: the query is compared too, so `…/uc?id=A`
/// and `…/uc?id=B` are different files. Only the parameters a refreshed signed
/// link changes are left out — AWS (`X-Amz-*`, `AWSAccessKeyId`), Google Cloud
/// Storage (`X-Goog-*`, `GoogleAccessId`), CloudFront (`Key-Pair-Id`,
/// `Policy`), Azure SAS (`sv`, `st`, `se`, `sr`, `sp`, `sig`, `spr`, `sip`),
/// and `Signature` / `Expires`. Fragment and credentials are ignored, and so is
/// the order of the parameters.
///
/// Internal to core.
bool sameDownloadSource(String downloaded, String requested) =>
    downloadSourceKey(downloaded) == downloadSourceKey(requested);

/// [url] as [sameDownloadSource] compares it: no credentials, no fragment, no
/// signing parameters, the rest of the query sorted. Also what core prints in
/// place of the URL, so a signature never reaches a log.
///
/// Internal to core.
String downloadSourceKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  final kept = <String>[
    for (final entry in uri.queryParametersAll.entries)
      if (!_isSigningParameter(entry.key))
        for (final value in entry.value)
          '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeQueryComponent(value)}',
  ]..sort();
  final base = _withoutQuery(url);
  return kept.isEmpty ? base : '$base?${kept.join('&')}';
}

const _signingParameters = {
  'awsaccesskeyid',
  'expires',
  'googleaccessid',
  'key-pair-id',
  'policy',
  'signature',
  // Azure shared access signatures.
  'se',
  'sig',
  'sip',
  'sp',
  'spr',
  'sr',
  'st',
  'sv',
};

bool _isSigningParameter(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('x-amz-') ||
      lower.startsWith('x-goog-') ||
      _signingParameters.contains(lower);
}

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
