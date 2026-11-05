/// The server prerenders the form too, and never submits it.
class ShowcaseSubmitApi {
  Future<String> submit(Map<String, Object?> data) => throw UnsupportedError('Submitting needs a browser');
}
