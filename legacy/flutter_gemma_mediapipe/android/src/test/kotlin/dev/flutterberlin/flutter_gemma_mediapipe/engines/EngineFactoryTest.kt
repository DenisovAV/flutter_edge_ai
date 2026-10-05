package dev.flutterberlin.flutter_gemma_mediapipe.engines

import android.content.Context
import dev.flutterberlin.flutter_gemma_mediapipe.engines.mediapipe.MediaPipeEngine
import org.junit.Assert.*
import org.junit.Test
import org.mockito.Mockito.mock

/**
 * Unit tests for EngineFactory.
 *
 * `.litertlm` files are handled by Dart-side FFI, not by this factory; the
 * factory only routes MediaPipe-format files (.task/.bin/.tflite).
 */
class EngineFactoryTest {

    private val mockContext: Context = mock(Context::class.java)

    @Test
    fun `createFromModelPath with task extension returns MediaPipeEngine`() {
        val engine = EngineFactory.createFromModelPath("/path/to/model.task", mockContext)
        assertTrue(engine is MediaPipeEngine)
    }

    @Test
    fun `createFromModelPath with bin extension returns MediaPipeEngine`() {
        val engine = EngineFactory.createFromModelPath("/path/to/model.bin", mockContext)
        assertTrue(engine is MediaPipeEngine)
    }

    @Test
    fun `createFromModelPath with tflite extension returns MediaPipeEngine`() {
        val engine = EngineFactory.createFromModelPath("/path/to/model.tflite", mockContext)
        assertTrue(engine is MediaPipeEngine)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `createFromModelPath with litertlm extension throws (handled by Dart FFI)`() {
        EngineFactory.createFromModelPath("/path/to/model.litertlm", mockContext)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `createFromModelPath with unknown extension throws`() {
        EngineFactory.createFromModelPath("/path/to/model.unknown", mockContext)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `createFromModelPath with no extension throws`() {
        EngineFactory.createFromModelPath("/path/to/model", mockContext)
    }

    @Test
    fun `createFromModelPath handles paths with multiple dots`() {
        val engine = EngineFactory.createFromModelPath("/path/to/model.v1.2.task", mockContext)
        assertTrue(engine is MediaPipeEngine)
    }

    @Test
    fun `createFromModelPath handles paths with spaces`() {
        val engine = EngineFactory.createFromModelPath("/path/to/my model.task", mockContext)
        assertTrue(engine is MediaPipeEngine)
    }
}
