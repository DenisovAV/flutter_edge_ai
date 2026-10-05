package dev.flutterberlin.flutter_gemma

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipFile

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterGemmaPlugin — core (engine-agnostic) Android plugin.
 *
 * Hosts the shared "flutter_gemma_bundled" MethodChannel used by core
 * file-ops (copyAssetToFile) and litertlm NPU dispatch
 * (getNativeLibraryDir → extractNpuLibsIfNeeded). MediaPipe (.task)
 * inference lives in the flutter_gemma_mediapipe package
 * (FlutterGemmaMediaPipePlugin + its PlatformService HostApi).
 */
class FlutterGemmaPlugin: FlutterPlugin {
  private lateinit var bundledChannel: MethodChannel
  private lateinit var context: Context

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext

    // Setup bundled assets channel
    bundledChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_gemma_bundled")
    bundledChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "copyAssetToFile" -> {
          try {
            val assetPath = call.argument<String>("assetPath")!!
            val destPath = call.argument<String>("destPath")!!
            copyAssetToFile(assetPath, destPath)
            result.success("success")
          } catch (e: Exception) {
            result.error("COPY_ERROR", e.message, null)
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

  private fun copyAssetToFile(assetPath: String, destPath: String) {
    val inputStream = context.assets.open(assetPath)
    val outputFile = File(destPath)
    outputFile.parentFile?.mkdirs()
    val outputStream = FileOutputStream(outputFile)

    inputStream.use { input ->
      outputStream.use { output ->
        input.copyTo(output, bufferSize = 8192)
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    bundledChannel.setMethodCallHandler(null)
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
        Log.w("FlutterGemma", "NPU: $libName not found in APK — skipping")
        continue
      }
      val outFile = File(outDir, libName)
      if (outFile.exists() && outFile.length() == entry.size) continue
      Log.i("FlutterGemma", "NPU: extracting $libName → ${outFile.absolutePath}")
      zip.getInputStream(entry).use { input ->
        FileOutputStream(outFile).use { output ->
          input.copyTo(output, bufferSize = 65536)
        }
      }
    }
  }

  Log.i("FlutterGemma", "NPU: dispatch_lib_dir=${outDir.absolutePath}")
  return outDir.absolutePath
}