package dev.flutterberlin.flutter_gemma_mediapipe.engines.mediapipe

import android.content.Context
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import dev.flutterberlin.flutter_gemma_mediapipe.PreferredBackend
import dev.flutterberlin.flutter_gemma_mediapipe.engines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.io.File

/**
 * Adapter wrapping existing MediaPipe LlmInference.
 *
 * This adapter wraps the existing MediaPipe implementation without
 * modifying the original InferenceModel logic.
 */
class MediaPipeEngine(
    private val context: Context
) : InferenceEngine {

    private var llmInference: LlmInference? = null

    override var isInitialized: Boolean = false
        private set

    override var capabilities = EngineCapabilities(
        supportsVision = true,
        supportsAudio = false, // Audio is LiteRT-LM only (not supported by MediaPipe SDK)
        supportsFunctionCalls = true, // Manual via chat templates
        supportsStreaming = true,
        supportsTokenCounting = true, // MediaPipe has sizeInTokens()
        maxTokenLimit = 2048,
    )

    // SharedFlow instances (same pattern as existing InferenceModel)
    private val _partialResults = FlowFactory.createSharedFlow<Pair<String, Boolean>>()
    override val partialResults: SharedFlow<Pair<String, Boolean>> = _partialResults.asSharedFlow()

    private val _errors = FlowFactory.createSharedFlow<Throwable>()
    override val errors: SharedFlow<Throwable> = _errors.asSharedFlow()

    override suspend fun initialize(config: EngineConfig) {
        // Validate model file exists
        if (!File(config.modelPath).exists()) {
            throw IllegalArgumentException("Model not found at path: ${config.modelPath}")
        }

        try {
            // Build LlmInferenceOptions (same logic as existing InferenceModel.kt)
            val optionsBuilder = LlmInference.LlmInferenceOptions.builder()
                .setModelPath(config.modelPath)
                .setMaxTokens(config.maxTokens)
                .apply {
                    config.supportedLoraRanks?.let { setSupportedLoraRanks(it) }
                    config.preferredBackend?.let {
                        // Map to MediaPipe Backend (NPU not supported)
                        val backendEnum: LlmInference.Backend? = when (it) {
                            PreferredBackend.CPU -> LlmInference.Backend.CPU
                            PreferredBackend.GPU -> LlmInference.Backend.GPU
                            PreferredBackend.NPU -> null // MediaPipe doesn't support NPU
                        }
                        backendEnum?.let { backend -> setPreferredBackend(backend) }
                    }
                    config.maxNumImages?.let { setMaxNumImages(it) }
                    // Enable audio model options when supportAudio is true
                    if (config.supportAudio == true) {
                        setAudioModelOptions(
                            com.google.mediapipe.tasks.genai.llminference.AudioModelOptions.builder().build()
                        )
                    }
                }

            val options = optionsBuilder.build()
            llmInference = LlmInference.createFromOptions(context, options)
            isInitialized = true
            // Update audio capability if audio was successfully configured
            if (config.supportAudio == true) {
                capabilities = capabilities.copy(supportsAudio = true)
            }
        } catch (e: Exception) {
            throw RuntimeException("Failed to initialize MediaPipe LlmInference: ${e.message}", e)
        }
    }

    override fun createSession(config: SessionConfig): InferenceSession {
        val inference = llmInference
            ?: throw IllegalStateException("Engine not initialized. Call initialize() first.")

        // Validate capabilities against config
        if (config.enableAudioModality == true && !capabilities.supportsAudio) {
            throw UnsupportedOperationException(
                "MediaPipe engine does not support audio. Use LiteRT-LM engine (.litertlm models) for audio support."
            )
        }

        return MediaPipeSession(inference, config, _partialResults, _errors)
    }

    override fun close() {
        llmInference?.close()
        llmInference = null
        isInitialized = false
    }
}
