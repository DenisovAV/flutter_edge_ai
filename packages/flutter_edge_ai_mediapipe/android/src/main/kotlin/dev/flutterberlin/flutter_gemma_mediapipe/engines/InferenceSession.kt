package dev.flutterberlin.flutter_gemma_mediapipe.engines

/**
 * Abstraction for inference sessions.
 *
 * API Design:
 * - addQueryChunk() accumulates text (supports both chunk-based and message-based APIs)
 * - addImage() accumulates images for multimodal
 * - generateResponse() / generateResponseAsync() triggers inference
 */
interface InferenceSession {
    /**
     * Add text chunk to current query.
     * Multiple calls accumulate into single message.
     */
    fun addQueryChunk(prompt: String)

    /**
     * Add image to current query (for multimodal models).
     * Throws UnsupportedOperationException if engine doesn't support vision.
     */
    fun addImage(imageBytes: ByteArray)

    /**
     * Add audio to current query (for multimodal models).
     * Throws UnsupportedOperationException if engine doesn't support audio.
     */
    fun addAudio(audioBytes: ByteArray)

    /**
     * Generate response synchronously (blocking).
     * Consumes accumulated chunks/images.
     */
    fun generateResponse(): String

    /**
     * Generate response asynchronously (streaming).
     * Consumes accumulated chunks/images.
     * Results emitted via engine's partialResults SharedFlow.
     */
    fun generateResponseAsync()

    /**
     * Estimate token count for text.
     * Returns approximate value if engine doesn't expose tokenizer.
     */
    fun sizeInTokens(prompt: String): Int

    /**
     * Cancel ongoing async generation.
     * No-op if generation already completed.
     */
    fun cancelGeneration()

    /** Release session resources */
    fun close()
}
