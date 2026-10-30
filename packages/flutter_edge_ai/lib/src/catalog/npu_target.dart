/// An NPU vendor. A class with constants rather than an enum, so a vendor
/// added in a later version does not break a `switch` written against this
/// one.
final class NpuVendor {
  const NpuVendor._(this.name);

  /// Qualcomm Hexagon (Snapdragon and Qualcomm Linux boards).
  static const qualcomm = NpuVendor._('qualcomm');

  /// Intel NPU (Lunar Lake, Panther Lake).
  static const intel = NpuVendor._('intel');

  /// The Google Tensor TPU (Pixel).
  static const googleTensor = NpuVendor._('google-tensor');

  /// MediaTek APU (Dimensity).
  static const mediatek = NpuVendor._('mediatek');

  /// The vendor's name in the model registry and on the website.
  final String name;

  @override
  String toString() => 'NpuVendor.$name';
}

/// The NPU a model file was compiled for. Engines extend this with the
/// details their files carry.
///
/// A target whose [npuVendor] is null must override `==` and `hashCode` by
/// value: [sameSoc] compares such targets with `==`, which without an
/// override is identity, so an app's `MyTarget('x1')` would match only the
/// catalog's own instance.
abstract base class NpuTarget {
  /// For subclasses.
  const NpuTarget();

  /// The vendor, or null for one this version of core has no name for.
  NpuVendor? get npuVendor;

  /// The SoC the file was compiled for, as its engine names it:
  /// `SM8750`, `QCS8275`, `PTL`, `Tensor_G5`, `mt6993`.
  String get socModel;

  /// Whether [other] is the same SoC: the same vendor and the same
  /// [socModel] without regard to case (`MT6991` is `mt6991`). For a vendor
  /// this version of core has no name for (`npuVendor` null, as for every
  /// NPU a third-party catalog adds), the two targets must be equal (`==`),
  /// so its own catalog can still pick it, and two such vendors never
  /// match each other by accident.
  bool sameSoc(NpuTarget other) {
    final vendor = npuVendor;
    if (vendor == null) return this == other;
    return vendor == other.npuVendor &&
        socModel.toLowerCase() == other.socModel.toLowerCase();
  }
}
