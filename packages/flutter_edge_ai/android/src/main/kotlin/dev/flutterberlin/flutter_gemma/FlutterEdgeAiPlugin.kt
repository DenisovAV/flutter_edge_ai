package dev.flutterberlin.flutter_gemma

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.zip.CRC32
import java.util.zip.CheckedInputStream
import java.util.zip.GZIPOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterEdgeAiPlugin — core (engine-agnostic) Android plugin.
 *
 * Hosts the shared "flutter_gemma_bundled" MethodChannel used by core
 * file-ops (copyAssetToFile) and litertlm NPU dispatch
 * (prepareNpuDispatchDir; the legacy getNativeLibraryDir →
 * extractNpuLibsIfNeeded stays for older litertlm versions). MediaPipe (.task)
 * inference lives in the flutter_edge_ai_mediapipe package
 * (FlutterEdgeAiMediaPipePlugin + its PlatformService HostApi).
 */
class FlutterEdgeAiPlugin: FlutterPlugin {
  private lateinit var bundledChannel: MethodChannel
  private lateinit var context: Context
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext

    // Setup bundled assets channel
    bundledChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_gemma_bundled")
    bundledChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "copyAssetToFile" -> {
          val assetPath = call.argument<String>("assetPath")
          val destPath = call.argument<String>("destPath")
          if (assetPath == null || destPath == null) {
            result.error("INVALID_ARGS", "assetPath and destPath are required", null)
          } else {
            // A bundled model can be hundreds of MB: copy it off the platform
            // thread, so the copy cannot freeze the UI or trigger an ANR, and
            // reply on the main thread, which MethodChannel.Result requires.
            BUNDLED_COPIES.execute {
              try {
                ensureAssetCopy(assetPath, File(destPath))
                mainHandler.post { result.success("success") }
              } catch (e: Exception) {
                mainHandler.post { result.error("COPY_ERROR", e.message, null) }
              }
            }
          }
        }
        "getNativeLibraryDir" -> {
          try {
            result.success(extractNpuLibsIfNeeded(context))
          } catch (e: Exception) {
            result.error("NATIVE_LIB_DIR_ERROR", e.message, null)
          }
        }
        "prepareNpuDispatchDir" -> {
          val libs = npuLibNames(call.arguments)
          if (libs == null) {
            result.error(
              "NPU_BAD_ARGS",
              "libs must be a non-empty list of distinct lib*.so file names, got: ${call.arguments}",
              null,
            )
          } else {
            // Extraction reads tens of MB out of the APKs: run it off the
            // platform thread, on an executor of its own so it never queues
            // behind a multi-GB BUNDLED_COPIES copy, and reply exactly once,
            // on the main thread. Throwable, not Exception: an Error must
            // still answer Dart instead of leaving its future pending.
            NPU_DISPATCH_DIRS.execute {
              try {
                val dir = prepareNpuDispatchDir(libs)
                mainHandler.post { result.success(dir) }
              } catch (e: NpuLibsMissingException) {
                Log.e(LOG_TAG, e.message ?: "NPU: libraries missing")
                mainHandler.post { result.error("NPU_LIBS_MISSING", e.message, null) }
              } catch (t: Throwable) {
                Log.e(LOG_TAG, "NPU: preparing the dispatch dir failed", t)
                val message = if (t is IOException) t.message else t.toString()
                mainHandler.post { result.error("NPU_PREPARE_FAILED", message, null) }
              }
            }
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  // Makes dest a copy of the asset from the installed APK. An existing file is
  // kept only when its marker says this app install copied it at its current
  // size. Anything else is copied again: a copy made by an earlier app version
  // (the asset may have changed in the update), a file another source left at
  // the same path (a download under the same name), or a copy from before
  // markers existed (possibly truncated). So a resource missing from the APK
  // is reported even when a file of that name is already on disk.
  private fun ensureAssetCopy(assetPath: String, dest: File) {
    val installedAt = appInstallTime()
    val markers = context.getSharedPreferences(COPY_MARKERS, Context.MODE_PRIVATE)
    if (dest.isFile && markers.getString(dest.path, null) == "$installedAt:${dest.length()}") {
      return
    }
    copyAssetToFile(assetPath, dest)
    markers.edit().putString(dest.path, "$installedAt:${dest.length()}").commit()
  }

  // When the installed APK last changed; an app update moves it forward.
  private fun appInstallTime(): Long {
    val packageManager = context.packageManager
    val info = if (Build.VERSION.SDK_INT >= 33) {
      packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
    } else {
      @Suppress("DEPRECATION")
      packageManager.getPackageInfo(context.packageName, 0)
    }
    return info.lastUpdateTime
  }

  // Writes a sibling temp file, syncs it to disk and renames it into place, so
  // neither a killed copy nor a power cut leaves a partial file at dest.
  private fun copyAssetToFile(assetPath: String, dest: File) {
    dest.parentFile?.mkdirs()
    val tempFile = File(dest.path + ".part")
    try {
      val (source, regzip) = openAsset(assetPath)
      source.use { input ->
        FileOutputStream(tempFile).use { file ->
          if (regzip) {
            GZIPOutputStream(file, BUFFER_SIZE).use { gzip ->
              input.copyTo(gzip, BUFFER_SIZE)
              gzip.finish()
              file.fd.sync()
            }
          } else {
            input.copyTo(file, BUFFER_SIZE)
            file.fd.sync()
          }
        }
      }
      if (!tempFile.renameTo(dest)) {
        throw IOException("Failed to move $tempFile to $dest")
      }
    } catch (e: Exception) {
      tempFile.delete()
      throw e
    }
  }

  // The Android build un-gzips an asset named *.gz and drops the suffix, so
  // "g2p_dict.txt.gz" ships as "g2p_dict.txt". Open that instead and report
  // that it must be compressed again, so the copy is the file that was asked for.
  private fun openAsset(assetPath: String): Pair<InputStream, Boolean> =
    try {
      context.assets.open(assetPath) to false
    } catch (e: FileNotFoundException) {
      if (!assetPath.endsWith(".gz")) throw e
      try {
        context.assets.open(assetPath.removeSuffix(".gz")) to true
      } catch (stripped: FileNotFoundException) {
        // Report the name that was asked for, not the fallback.
        e.addSuppressed(stripped)
        throw e
      }
    }

  // The argument map's "libs", or null unless it is a non-empty list of
  // distinct plain file names: no separators, so a name can only ever address
  // a file directly inside the dir this method owns.
  private fun npuLibNames(arguments: Any?): List<String>? {
    val raw = (arguments as? Map<*, *>)?.get("libs") as? List<*> ?: return null
    val names = raw.map { it as? String ?: return null }
    if (names.isEmpty() || names.toSet().size != names.size) return null
    return if (names.all { NPU_LIB_NAME.matches(it) }) names else null
  }

  // LiteRT's Qualcomm dispatch opendir()-scans dispatch_lib_dir, so every
  // library it needs must exist there as a real file. The list comes from
  // Dart, because flutter_edge_ai_litertlm decides per build what it bundles.
  // Returns a dir holding all of them, or throws: never a partial dir, which
  // would surface much later as a dispatch failure far from its cause.
  private fun prepareNpuDispatchDir(libs: List<String>): String {
    val started = System.nanoTime()
    val appInfo = context.applicationInfo

    // Legacy packaging (extractNativeLibs=true): the installer already wrote
    // every lib to nativeLibraryDir. Check each file, not the dir: the dir
    // exists, empty, when the libs stay inside the APK.
    val installed = appInfo.nativeLibraryDir?.let(::File)
    if (installed != null && libs.all { File(installed, it).let { f -> f.isFile && f.length() > 0 } }) {
      val bytes = libs.sumOf { File(installed, it).length() }
      Log.i(LOG_TAG, "NPU: dispatch_lib_dir=${installed.path} (nativeLibraryDir, " +
          "${libs.size} libs, $bytes bytes, ${elapsedMs(started)} ms)")
      return installed.absolutePath
    }

    // Otherwise the libs are entries of an installed APK: the base APK for a
    // plain APK install, the ABI config split (split_config.arm64_v8a.apk)
    // for a Play/AAB install.
    val apkPaths = listOf(appInfo.sourceDir) + (appInfo.splitSourceDirs?.toList() ?: emptyList())
    val apks = ArrayList<ZipFile>(apkPaths.size)
    try {
      apkPaths.mapTo(apks) { ZipFile(it) }
      val sources = ArrayList<NpuLibSource>(libs.size)
      val missing = ArrayList<String>()
      for (name in libs.sorted()) {
        var source: NpuLibSource? = null
        for ((i, apk) in apks.withIndex()) {
          val entry = apk.getEntry("$NPU_ABI_DIR$name") ?: continue
          source = NpuLibSource(name, apkPaths[i], apk, entry)
          break
        }
        if (source == null) missing += name else sources += source
      }
      if (missing.isNotEmpty()) {
        throw NpuLibsMissingException("NPU: ${missing.joinToString()} not found under " +
            "$NPU_ABI_DIR in ${apkPaths.joinToString()}")
      }

      // Content key from zip metadata only (no data read): the same libs at
      // the same size and CRC always land in the same dir, so a ready dir is
      // reused, and different contents can never be mistaken for it.
      val digest = MessageDigest.getInstance("SHA-256")
      for (s in sources) {
        digest.update("${s.name}\u0000${s.entry.size}\u0000${s.entry.crc}\n".toByteArray(Charsets.UTF_8))
      }
      val key = digest.digest()
        .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
        .take(16)
      val marker = sources.joinToString("") { "${it.name}\t${it.entry.size}\n" }
      val bytes = sources.sumOf { it.entry.size }
      val from = sources.map { it.apkPath }.distinct().joinToString()
      val codeCache = context.codeCacheDir
      val target = File(codeCache, "$NPU_DIR_PREFIX$key")

      synchronized(NPU_DISPATCH_LOCK) {
        if (npuDirIsComplete(target, sources, marker)) {
          Log.i(LOG_TAG, "NPU: dispatch_lib_dir=${target.path} (reused, ${sources.size} libs, " +
              "$bytes bytes from $from, ${elapsedMs(started)} ms)")
          return target.absolutePath
        }
        // A target that exists but does not validate (a file damaged on disk)
        // would make the rename below fail on every call: remove it first.
        if (target.exists() && !target.deleteRecursively()) {
          throw IOException("NPU: cannot remove invalid ${target.path}")
        }
        // Built beside the target and renamed into place last, so the target
        // is either absent or complete, even if the process dies mid-copy.
        val tmp = File(codeCache, "$NPU_TMP_PREFIX${Process.myPid()}-${System.nanoTime()}")
        try {
          if (!tmp.mkdirs()) throw IOException("NPU: cannot create ${tmp.path}")
          for (source in sources) extractNpuLib(source, File(tmp, source.name))
          FileOutputStream(File(tmp, NPU_MARKER)).use { out ->
            out.write(marker.toByteArray(Charsets.UTF_8))
            out.fd.sync()
          }
          if (!tmp.renameTo(target)) {
            // Another process (its own FlutterEngine) may have renamed its
            // copy into place first; the lock only covers this process.
            if (!npuDirIsComplete(target, sources, marker)) {
              throw IOException("NPU: failed to move ${tmp.path} to ${target.path}")
            }
            tmp.deleteRecursively()
            Log.i(LOG_TAG, "NPU: ${target.path} was prepared by another process meanwhile")
          }
        } catch (t: Throwable) {
          tmp.deleteRecursively()
          throw t
        }
        removeStaleNpuDirs(codeCache, keep = target.name)
        Log.i(LOG_TAG, "NPU: dispatch_lib_dir=${target.path} (extracted ${sources.size} libs, " +
            "$bytes bytes from $from, ${elapsedMs(started)} ms)")
        return target.absolutePath
      }
    } finally {
      for (apk in apks) {
        try {
          apk.close()
        } catch (e: IOException) {
          Log.w(LOG_TAG, "NPU: closing ${apk.name} failed", e)
        }
      }
    }
  }

  // Streams one entry to dest and checks it against the zip metadata the
  // content key was built from, then syncs it, so the marker written after it
  // never vouches for bytes that are not on disk.
  private fun extractNpuLib(source: NpuLibSource, dest: File) {
    val crc = CRC32()
    val copied = CheckedInputStream(source.zip.getInputStream(source.entry), crc).use { input ->
      FileOutputStream(dest).use { output ->
        input.copyTo(output, BUFFER_SIZE).also { output.fd.sync() }
      }
    }
    if (copied != source.entry.size || crc.value != source.entry.crc) {
      throw IOException("NPU: ${source.name} from ${source.apkPath} read $copied bytes, " +
          "crc ${crc.value}; zip says ${source.entry.size} bytes, crc ${source.entry.crc}")
    }
    if (!dest.setReadOnly()) throw IOException("NPU: cannot make ${dest.path} read-only")
  }

  // Complete = the marker (written last) lists exactly these libs at these
  // sizes, and every file is still there at that size.
  private fun npuDirIsComplete(dir: File, sources: List<NpuLibSource>, marker: String): Boolean {
    val markerFile = File(dir, NPU_MARKER)
    if (!markerFile.isFile || markerFile.readText(Charsets.UTF_8) != marker) return false
    return sources.all { File(dir, it.name).let { f -> f.isFile && f.length() == it.entry.size } }
  }

  // code_cache is wiped by the OS on every app or platform update, and installd
  // also purges it file by file under storage pressure (npuDirIsComplete then
  // fails and the next call extracts again). What is left here belongs to this
  // install: temp dirs of a killed extraction and the legacy npu_libs dir.
  // Another npu_libs-<key> dir is kept: within one install a second key can
  // only come from a different library list, whose engine may be live.
  // Housekeeping only: a dir that will not go is logged, the target returned.
  private fun removeStaleNpuDirs(codeCache: File, keep: String) {
    val children = codeCache.listFiles()
    if (children == null) {
      Log.w(LOG_TAG, "NPU: cannot list ${codeCache.path} to remove stale dirs")
      return
    }
    for (child in children) {
      val name = child.name
      if (name == keep) continue
      if (name != NPU_LEGACY_DIR && !name.startsWith(NPU_TMP_PREFIX)) continue
      // A temp dir may belong to another process of this app (a second
      // FlutterEngine in a :service process) extracting right now — the lock
      // here is per process. Only an old one is a leftover of a killed run.
      if (name.startsWith(NPU_TMP_PREFIX) &&
        System.currentTimeMillis() - child.lastModified() < NPU_TMP_STALE_MS) continue
      if (!child.deleteRecursively()) Log.w(LOG_TAG, "NPU: could not remove stale ${child.path}")
    }
  }

  private fun elapsedMs(startedNanos: Long): Long = (System.nanoTime() - startedNanos) / 1_000_000

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    bundledChannel.setMethodCallHandler(null)
  }

  private companion object {
    // One copy at a time for the whole process, so two engines asking for the
    // same resource take turns instead of writing one temp file at once.
    val BUNDLED_COPIES: ExecutorService = Executors.newSingleThreadExecutor { task ->
      Thread(task, "flutter_edge_ai-bundled-copy").apply { isDaemon = true }
    }
    const val COPY_MARKERS = "flutter_edge_ai_bundled_copies"
    const val BUFFER_SIZE = 1 shl 16
    const val LOG_TAG = "FlutterEdgeAi"

    // NPU dispatch dirs get an executor of their own, so preparing one never
    // waits behind a multi-GB BUNDLED_COPIES copy. The lock is process-wide
    // (one plugin instance per FlutterEngine): two engines never extract into
    // or clean up code_cache at the same time.
    val NPU_DISPATCH_DIRS: ExecutorService = Executors.newSingleThreadExecutor { task ->
      Thread(task, "flutter_edge_ai-npu-dispatch").apply { isDaemon = true }
    }
    val NPU_DISPATCH_LOCK = Any()
    val NPU_LIB_NAME = Regex("lib[A-Za-z0-9._+-]+\\.so")
    const val NPU_ABI_DIR = "lib/arm64-v8a/"
    const val NPU_DIR_PREFIX = "npu_libs-"
    const val NPU_TMP_PREFIX = "npu_libs.tmp-"
    const val NPU_TMP_STALE_MS = 10 * 60 * 1000L
    const val NPU_LEGACY_DIR = "npu_libs"
    const val NPU_MARKER = ".complete"
  }
}

// One requested NPU library: the APK that holds it and its entry there.
private class NpuLibSource(
  val name: String,
  val apkPath: String,
  val zip: ZipFile,
  val entry: ZipEntry,
)

// A requested library is in none of the installed APKs → NPU_LIBS_MISSING.
private class NpuLibsMissingException(message: String) : Exception(message)

// Legacy path behind getNativeLibraryDir, unchanged for flutter_edge_ai_litertlm
// versions that still call it; newer versions call prepareNpuDispatchDir.
//
// LiteRT's litert_dispatch.cc uses opendir() to scan dispatch_lib_dir for
// libLiteRtDispatch_*.so. With AGP 8+ default extractNativeLibs=false, .so
// files are stored in the APK but not extracted to the filesystem, so opendir
// finds nothing. We extract the QNN dispatch stack to a private cache dir on
// first NPU use so LiteRT can find them via filesystem scan.
private val NPU_LIBS = listOf(
  "libLiteRtDispatch_Qualcomm.so",
  "libQnnHtp.so",
  "libQnnSystem.so",
  "libQnnHtpV73Stub.so",
  "libQnnHtpV73Skel.so",
  "libQnnHtpV75Stub.so",
  "libQnnHtpV75Skel.so",
  "libQnnHtpV79Stub.so",
  "libQnnHtpV79Skel.so",
  "libQnnHtpV81Stub.so",
  "libQnnHtpV81Skel.so",
)

private fun extractNpuLibsIfNeeded(context: Context): String {
  val outDir = File(context.codeCacheDir, "npu_libs")
  if (!outDir.mkdirs() && !outDir.isDirectory) {
    throw java.io.IOException("NPU: failed to create extraction dir: ${outDir.absolutePath}")
  }

  val apkPath = context.applicationInfo.sourceDir
  ZipFile(apkPath).use { zip ->
    for (libName in NPU_LIBS) {
      val entry = zip.getEntry("lib/arm64-v8a/$libName")
      if (entry == null) {
        Log.w("FlutterEdgeAi", "NPU: $libName not found in APK — skipping")
        continue
      }
      val outFile = File(outDir, libName)
      if (outFile.exists() && outFile.length() == entry.size) continue
      Log.i("FlutterEdgeAi", "NPU: extracting $libName → ${outFile.absolutePath}")
      zip.getInputStream(entry).use { input ->
        FileOutputStream(outFile).use { output ->
          input.copyTo(output, bufferSize = 65536)
        }
      }
    }
  }

  Log.i("FlutterEdgeAi", "NPU: dispatch_lib_dir=${outDir.absolutePath}")
  return outDir.absolutePath
}