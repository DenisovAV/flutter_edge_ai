/// A submission the function did not take, with its reason for the person.
class SubmitException implements Exception {
  SubmitException(this.message);

  final String message;

  @override
  String toString() => 'SubmitException: $message';
}
