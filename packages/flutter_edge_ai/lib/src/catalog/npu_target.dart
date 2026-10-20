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
abstract base class NpuTarget {
  /// For subclasses.
  const NpuTarget();

  /// The vendor, or null for one this version of core has no name for.
  NpuVendor? get npuVendor;

  /// The SoC the file was compiled for, as its engine names it:
  /// `SM8750`, `QCS8275`, `PTL`, `Tensor_G5`, `mt6993`.
  String get socModel;

  /// Whether [other] is the same SoC.
  bool sameSoc(NpuTarget other) =>
      npuVendor == other.npuVendor && socModel == other.socModel;
}
