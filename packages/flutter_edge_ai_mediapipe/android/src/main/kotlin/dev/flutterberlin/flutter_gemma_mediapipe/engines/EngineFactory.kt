package dev.flutterberlin.flutter_gemma_mediapipe.engines

import android.content.Context
import dev.flutterberlin.flutter_gemma_mediapipe.engines.mediapipe.MediaPipeEngine

/**
 * Factory for creating MediaPipe inference engines.
 *
 * `.litertlm` files are handled by Dart-side FFI (`LiteRtLmFfiClient` in
 * `lib/core/ffi/`) on Android, iOS and desktop, so they never reach this
 * factory. Only MediaPipe-format files are routed through Kotlin.
 */
object EngineFactory {

    /**
     * Create engine based on file extension.
     *
     * @param modelPath Path to model file
     * @param context Android context
     * @return MediaPipe engine instance
     * @throws IllegalArgumentException if file extension not recognized or
     *         is `.litertlm` (those go through Dart FFI, not this factory)
     */
    fun createFromModelPath(modelPath: String, context: Context): InferenceEngine {
        return when {
            modelPath.endsWith(".task", ignoreCase = true) -> MediaPipeEngine(context)
            modelPath.endsWith(".bin", ignoreCase = true) -> MediaPipeEngine(context)
            modelPath.endsWith(".tflite", ignoreCase = true) -> MediaPipeEngine(context)
            modelPath.endsWith(".litertlm", ignoreCase = true) ->
                throw IllegalArgumentException(
                    "$modelPath is a LiteRT-LM model — it should be handled by " +
                    "Dart FFI (LiteRtLmFfiClient), not by EngineFactory."
                )
            else -> {
                val extension = if (modelPath.contains('.')) {
                    modelPath.substringAfterLast('.')
                } else {
                    "<no extension>"
                }
                throw IllegalArgumentException(
                    "Unsupported model format: .$extension. " +
                    "Supported: .task/.bin/.tflite (MediaPipe)"
                )
            }
        }
    }
}
