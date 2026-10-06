package dev.flutterberlin.flutter_gemma_mediapipe.engines

import java.util.concurrent.Executor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ReleaseGateTest {

  private val closed = mutableListOf<String>()
  private val warnings = mutableListOf<String>()
  private val queued = mutableListOf<Runnable>()

  // Holds released work until the test runs it, the way MediaPipe's callback
  // thread hands off to the release thread.
  private val executor = Executor { queued += it }
  private val gate = ReleaseGate(executor) { warnings += it }

  private fun drain() {
    val pending = queued.toList()
    queued.clear()
    pending.forEach(Runnable::run)
  }

  @Test
  fun `releases at once when nothing is generating`() {
    gate.retire(session = FakeSession("s", closed))
    assertEquals(listOf("s"), closed)
  }

  @Test
  fun `holds a release back until the generation ends`() {
    gate.begin()
    gate.retire(session = FakeSession("s", closed), engine = FakeEngine("e", closed))
    assertTrue(closed.isEmpty())

    gate.end()
    assertTrue(closed.isEmpty(), "the release must not run on the callback thread")
    drain()
    assertEquals(listOf("s", "e"), closed)
  }

  @Test
  fun `waits for the last of several generations`() {
    gate.begin()
    gate.begin()
    gate.retire(engine = FakeEngine("e", closed))
    gate.end()
    drain()
    assertTrue(closed.isEmpty())
    gate.end()
    drain()
    assertEquals(listOf("e"), closed)
  }

  @Test
  fun `closes sessions before engines whatever the retire order`() {
    gate.begin()
    gate.retire(engine = FakeEngine("e", closed))
    gate.retire(session = FakeSession("s", closed))
    gate.end()
    drain()
    assertEquals(listOf("s", "e"), closed)
  }

  @Test
  fun `a failing close is logged, not thrown, and the rest still close`() {
    gate.retire(
      session = FakeSession("s", closed, fail = true),
      engine = FakeEngine("e", closed),
    )
    assertEquals(listOf("e"), closed)
    assertEquals(1, warnings.size)
  }

  @Test
  fun `an extra end does not let a later release through early`() {
    gate.end()
    gate.begin()
    gate.retire(session = FakeSession("s", closed))
    drain()
    assertTrue(closed.isEmpty())
  }

  private class FakeSession(
    private val name: String,
    private val closed: MutableList<String>,
    private val fail: Boolean = false,
  ) : InferenceSession {
    override fun addQueryChunk(prompt: String) = Unit
    override fun addImage(imageBytes: ByteArray) = Unit
    override fun addAudio(audioBytes: ByteArray) = Unit
    override fun generateResponse(): String = ""
    override fun generateResponseAsync(onSettled: () -> Unit) = Unit
    override fun sizeInTokens(prompt: String): Int = 0
    override fun cancelGeneration() = Unit
    override fun close() {
      if (fail) throw IllegalStateException("Previous invocation still processing.")
      closed += name
    }
  }

  private class FakeEngine(
    private val name: String,
    private val closed: MutableList<String>,
  ) : InferenceEngine {
    override val isInitialized = true
    override val capabilities = EngineCapabilities()
    override val partialResults =
      kotlinx.coroutines.flow.MutableSharedFlow<Pair<String, Boolean>>()
    override val errors = kotlinx.coroutines.flow.MutableSharedFlow<Throwable>()
    override suspend fun initialize(config: EngineConfig) = Unit
    override fun createSession(config: SessionConfig): InferenceSession =
      throw UnsupportedOperationException()
    override fun close() {
      closed += name
    }
  }
}
