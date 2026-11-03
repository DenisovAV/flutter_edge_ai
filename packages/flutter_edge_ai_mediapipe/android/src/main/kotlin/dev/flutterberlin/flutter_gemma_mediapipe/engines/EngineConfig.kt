package dev.flutterberlin.flutter_gemma_mediapipe.engines

import dev.flutterberlin.flutter_gemma_mediapipe.PreferredBackend
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * Engine initialization configuration.
 */
data class EngineConfig(
    val modelPath: String,
    val maxTokens: Int,
    val supportedLoraRanks: List<Int>? = null,
    val preferredBackend: PreferredBackend? = null,
    val maxNumImages: Int? = null,
    val supportAudio: Boolean? = null,
)

/**
 * Session-level configuration (sampling parameters).
 */
data class SessionConfig(
    val temperature: Float = 1.0f,
    val randomSeed: Int = 0,
    val topK: Int = 40,
    val topP: Float? = null,
    val loraPath: String? = null,
    val enableVisionModality: Boolean? = null,
    val enableAudioModality: Boolean? = null,
    val systemInstruction: String? = null,
    val enableThinking: Boolean = false,
)

/**
 * Helper to create SharedFlow instances with consistent configuration.
 *
 * The buffer is unbounded and never drops: generation callbacks `tryEmit`
 * each chunk while the collector waits for the main thread to hand the
 * previous one to Dart, so a bounded drop-oldest buffer lost chunks whenever
 * the UI thread was busy, and the turn still ended as done. A chunk is a few
 * characters, and a turn emits at most a few thousand.
 */
object FlowFactory {
    fun <T> createSharedFlow(): MutableSharedFlow<T> = MutableSharedFlow(
        extraBufferCapacity = Channel.UNLIMITED,
        onBufferOverflow = BufferOverflow.SUSPEND
    )
}
