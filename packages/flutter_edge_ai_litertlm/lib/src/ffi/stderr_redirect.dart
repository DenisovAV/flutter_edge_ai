import 'dart:ffi';

typedef _FdNative = Int32 Function(Int32 fd);
typedef _Fd = int Function(int fd);
typedef _Dup2Native = Int32 Function(Int32 from, Int32 to);
typedef _Dup2 = int Function(int from, int to);

/// The outcome of [redirectStderrKeepingStdout].
typedef StderrRedirectResult = ({int? rc, String? restoreError});

/// Runs [redirect] (`stream_proxy_redirect_stderr`), then puts stdout back
/// where it was. POSIX only.
///
/// The shipped redirect dup2s its log file onto fd 1 as well as fd 2. The
/// macOS and Linux engines write `print` to stdout and `flutter run` reads
/// the app's stdout, so after the first model load every print of a debug
/// build went to the log file instead of the console. iOS prints go to
/// syslog and `flutter test` reads them over the VM service, which is why
/// neither showed it.
///
/// `rc` is null when stdout could not be saved: [redirect] is not called and
/// nothing moves. Otherwise it is the redirect's status, and `restoreError`
/// says why stdout could not be put back, if it could not. [stdoutFd] exists
/// for the test, which cannot hand over the runner's own stdout.
StderrRedirectResult redirectStderrKeepingStdout(
  int Function() redirect, {
  int stdoutFd = 1,
}) {
  final libc = DynamicLibrary.process();
  final dup = libc.lookupFunction<_FdNative, _Fd>('dup');
  final dup2 = libc.lookupFunction<_Dup2Native, _Dup2>('dup2');
  final close = libc.lookupFunction<_FdNative, _Fd>('close');
  final saved = dup(stdoutFd);
  if (saved < 0) return (rc: null, restoreError: null);
  try {
    final rc = redirect();
    final back = dup2(saved, stdoutFd);
    return (
      rc: rc,
      restoreError: back < 0 ? 'dup2(saved, $stdoutFd) returned $back' : null,
    );
  } finally {
    close(saved);
  }
}
