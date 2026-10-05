package dev.flutterberlin.flutter_gemma_mediapipe.engines.mediapipe

import android.graphics.BitmapFactory
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.genai.llminference.GraphOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import android.util.Log
import dev.flutterberlin.flutter_gemma_mediapipe.engines.*
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * Adapter wrapping MediaPipe LlmInferenceSession.
 *
 * Direct pass-through to existing MediaPipe implementation.
 * Same logic as existing InferenceModelSession.kt.
 */
class MediaPipeSession(
    private val llmInference: LlmInference,
    config: SessionConfig,
    private val resultFlow: MutableSharedFlow<Pair<String, Boolean>>,
    private val errorFlow: MutableSharedFlow<Throwable>
) : InferenceSession {

    companion object {
        private const val TAG = "MediaPipeSession"
    }

    private val session: LlmInferenceSession

    init {
        // Same session creation logic as existing InferenceModelSession.kt
        val sessionOptionsBuilder = LlmInferenceSession.LlmInferenceSessionOptions.builder()
            .setTemperature(config.temperature)
            .setRandomSeed(config.randomSeed)
            .setTopK(config.topK)
            .apply {
                config.topP?.let { setTopP(it) }
                config.loraPath?.let { setLoraPath(it) }
                // Set GraphOptions for vision and/or audio modality
                val enableVision = config.enableVisionModality
                val enableAudio = config.enableAudioModality
                if (enableVision != null || enableAudio != null) {
                    val graphOptionsBuilder = GraphOptions.builder()
                    enableVision?.let { graphOptionsBuilder.setEnableVisionModality(it) }
                    enableAudio?.let { graphOptionsBuilder.setEnableAudioModality(it) }
                    setGraphOptions(graphOptionsBuilder.build())
                }
            }

        val sessionOptions = sessionOptionsBuilder.build()
        session = LlmInferenceSession.createFromOptions(llmInference, sessionOptions)

        if (config.enableThinking) {
            Log.w(TAG, "enableThinking=true is not supported by MediaPipe engine. " +
                "Use LiteRT-LM (.litertlm) models for thinking mode.")
        }
    }

    override fun addQueryChunk(prompt: String) {
        session.addQueryChunk(prompt)
    }

    override fun addImage(imageBytes: ByteArray) {
        val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: throw IllegalArgumentException("Failed to decode image bytes")
        val mpImage = BitmapImageBuilder(bitmap).build()
        session.addImage(mpImage)
    }

    override fun addAudio(audioBytes: ByteArray) {
        session.addAudio(audioBytes)
    }

    override fun generateResponse(): String {
        return try {
            session.generateResponse()
                ?: throw RuntimeException("MediaPipe returned null response")
        } catch (e: Exception) {
            Log.e(TAG, "Error generating response", e)
            errorFlow.tryEmit(e)
            throw e
        }
    }

    override fun generateResponseAsync() {
        session.generateResponseAsync { result, done ->
            if (result != null) {
                resultFlow.tryEmit(result to done)
            } else if (done) {
                resultFlow.tryEmit("" to true)
            }
        }
    }

    /**
     * Multi-session streaming: drive the callback directly instead of the
     * shared [resultFlow], so the plugin can tag each chunk with its
     * sessionId and demux on the Dart side. Bypasses the SharedFlow entirely
     * — the legacy singleton path ([generateResponseAsync]) is untouched.
     */
    fun generateResponseAsyncTagged(onResult: (String, Boolean) -> Unit) {
        session.generateResponseAsync { result, done ->
            if (result != null) {
                onResult(result, done)
            } else if (done) {
                onResult("", true)
            }
        }
    }

    override fun sizeInTokens(prompt: String): Int {
        return session.sizeInTokens(prompt)
    }

    override fun cancelGeneration() {
        try {
            session.cancelGenerateResponseAsync()
        } catch (e: Exception) {
            Log.w(TAG, "cancelGeneration failed", e)
        }
    }

    override fun close() {
        session.close()
    }
}
