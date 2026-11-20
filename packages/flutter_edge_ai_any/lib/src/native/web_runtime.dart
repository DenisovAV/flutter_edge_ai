// The web has no libany_shim: any-sync's transports (QUIC, TCP, mDNS) and
// its tree storage have no browser build. canHandle is false there and
// AnySyncAccount.open throws UnsupportedError.
import 'any_native.dart';

AnyNative createAnyNative() => const _NoNative();

final class _NoNative implements AnyNative {
  const _NoNative();

  @override
  bool get supported => false;

  static Never _unsupported() => throw UnsupportedError(
    'flutter_edge_ai_any has no web implementation: any-sync needs native '
    'transports and storage.',
  );

  @override
  Future<AnyRuntime> start() async => _unsupported();

  @override
  Future<String> newMnemonic() async => _unsupported();

  @override
  Future<String> newDeviceKey() async => _unsupported();
}
