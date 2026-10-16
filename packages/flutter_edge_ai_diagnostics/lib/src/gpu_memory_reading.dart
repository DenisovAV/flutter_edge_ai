import 'package:meta/meta.dart';

/// Where a [GpuMemoryReading] came from.
enum GpuMemorySource {
  /// The process's `kgsl-3d0` mappings in `/proc/self/smaps`: the buffers the
  /// Qualcomm Adreno driver maps into the process.
  adrenoKgslMappings,
}

/// GPU driver memory that is mapped into this process, from
/// `FlutterEdgeAiDiagnostics.gpuMemory`. **Experimental**: vendor-specific, and
/// it may change or go away.
///
/// This is the part of the GPU's memory that the process maps, not all of it.
/// Memory the driver holds for the process without mapping it is not here;
/// [outsideSnapshotBytes] is where it would be.
///
/// It is a **view of memory already counted** by `MemorySnapshot`, not another
/// bucket: each number says which one it overlaps. It is a reading, not a
/// delta, so it includes what the app's own rendering maps (about 6 MiB in a
/// Flutter app); take one before loading a model and subtract.
@experimental
@immutable
final class GpuMemoryReading {
  /// Creates a reading. Apps get one from `FlutterEdgeAiDiagnostics`.
  const GpuMemoryReading({
    required this.source,
    required this.inAnonymousBytes,
    required this.inFileBackedBytes,
    required this.takenAt,
    this.outsideSnapshotBytes,
  });

  /// Where the numbers were read.
  final GpuMemorySource source;

  /// The `Private_Dirty` of the GPU mappings, in bytes: already in
  /// `MemorySnapshot.anonymousBytes`.
  final int inAnonymousBytes;

  /// The `Private_Clean + Shared_Clean` of the GPU mappings, in bytes: already
  /// in `MemorySnapshot.fileBackedBytes`. This is what to subtract from it to
  /// get the non-GPU file-backed memory.
  final int inFileBackedBytes;

  /// GPU memory the driver holds for this process without mapping it, in bytes,
  /// which no `MemorySnapshot` field includes. Null: not readable here. It is
  /// null in this version everywhere: the kernel's per-process counters for it
  /// are in `/sys/class/kgsl`, which an app could not read on the one device
  /// tried (a vivo 1933, Android 11).
  final int? outsideSnapshotBytes;

  /// When this reading was taken.
  final DateTime takenAt;

  @override
  bool operator ==(Object other) =>
      other is GpuMemoryReading &&
      other.source == source &&
      other.inAnonymousBytes == inAnonymousBytes &&
      other.inFileBackedBytes == inFileBackedBytes &&
      other.outsideSnapshotBytes == outsideSnapshotBytes &&
      other.takenAt == takenAt;

  @override
  int get hashCode => Object.hash(
    source,
    inAnonymousBytes,
    inFileBackedBytes,
    outsideSnapshotBytes,
    takenAt,
  );

  @override
  String toString() =>
      'GpuMemoryReading(source: $source, inAnonymousBytes: $inAnonymousBytes, '
      'inFileBackedBytes: $inFileBackedBytes, '
      'outsideSnapshotBytes: $outsideSnapshotBytes, takenAt: $takenAt)';
}
