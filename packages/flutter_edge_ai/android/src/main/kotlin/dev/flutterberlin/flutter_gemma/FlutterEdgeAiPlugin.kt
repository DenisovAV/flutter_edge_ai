package dev.flutterberlin.flutter_gemma

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
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
  // A bundled model can be hundreds of MB. Copy it off the platform thread so
  // the copy cannot freeze the UI or trigger an ANR, and reply on the main
  // thread, which MethodChannel.Result requires.
  private lateinit var copyExecutor: ExecutorService
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    copyExecutor = Executors.newSingleThreadExecutor()

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
            copyExecutor.execute {
              try {
                copyAssetToFile(assetPath, destPath)
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

  // Writes a sibling temp file and renames it into place. The Dart side treats
  // an existing destPath as already copied, so a copy killed halfway must never
  // leave a truncated file there.
  private fun copyAssetToFile(assetPath: String, destPath: String) {
    val outputFile = File(destPath)
    outputFile.parentFile?.mkdirs()
    val tempFile = File(outputFile.path + ".part")
    try {
      val (source, regzip) = openAsset(assetPath)
      source.use { input ->
        val file = FileOutputStream(tempFile)
        val output: OutputStream = if (regzip) GZIPOutputStream(file, 1 shl 16) else file
        output.use { input.copyTo(it, bufferSize = 1 shl 16) }
      }
      if (!tempFile.renameTo(outputFile)) {
        throw IOException("Failed to move $tempFile to $outputFile")
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
      context.assets.open(assetPath.removeSuffix(".gz")) to true
    }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    bundledChannel.setMethodCallHandler(null)
    copyExecutor.shutdown()
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