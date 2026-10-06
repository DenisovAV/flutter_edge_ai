package dev.flutterberlin.flutter_gemma

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.zip.GZIPOutputStream
import java.util.zip.ZipFile

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterEdgeAiPlugin — core (engine-agnostic) Android plugin.
 *
 * Hosts the shared "flutter_gemma_bundled" MethodChannel used by core
 * file-ops (copyAssetToFile) and litertlm NPU dispatch
 * (getNativeLibraryDir → extractNpuLibsIfNeeded). MediaPipe (.task)
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
  }
}

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