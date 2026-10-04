package dev.flutterberlin.flutter_gemma_mediapipe.engines

import kotlinx.coroutines.flow.SharedFlow

/**
 * Abstraction for inference engines (MediaPipe, LiteRT-LM, future engines).
 *
 * Lifecycle:
 * 1. initialize(config) - Load model, setup backend
 * 2. createSession(config) - Create conversation/session
 * 3. close() - Release resources
 */
interface InferenceEngine {
    /** Whether engine has been initialized successfully */
    val isInitialized: Boolean

    /** Engine capabilities (vision, audio, function calls) */
    val capabilities: EngineCapabilities

    /** Streaming outputs (partial results + errors) */
    val partialResults: SharedFlow<Pair<String, Boolean>>
    val errors: SharedFlow<Throwable>

    /**
     * Initialize engine with model file.
     * MUST be called on background thread (can take 10+ seconds).
     */
    suspend fun initialize(config: EngineConfig)

    /**
     * Create a new inference session.
     * Throws IllegalStateException if engine not initialized.
     */
    fun createSession(config: SessionConfig): InferenceSession

    /** Release all resources */
    fun close()
}

/**
 * Engine capabilities descriptor.
 */
data class EngineCapabilities(
    val supportsVision: Boolean = false,
    val supportsAudio: Boolean = false,
    val supportsFunctionCalls: Boolean = false,
    val supportsStreaming: Boolean = true,
    val supportsTokenCounting: Boolean = false,
    val maxTokenLimit: Int = 2048,
)
