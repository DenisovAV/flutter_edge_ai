package dev.flutterberlin.flutter_gemma_mediapipe.engines

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The generation callback emits each chunk with tryEmit while the collector
 * is still handing the previous one to the main thread. No chunk may be lost.
 */
class FlowFactoryTest {

    @Test
    fun `a slow collector receives every chunk the generator emits`() = runBlocking {
        val flow = FlowFactory.createSharedFlow<Pair<String, Boolean>>()
        val received = async(start = CoroutineStart.UNDISPATCHED) {
            flow.takeWhile { (_, done) -> !done }.toList()
        }
        // Subscribed, as PlatformServiceImpl is before generation starts.
        while (flow.subscriptionCount.value == 0) delay(1)
        // No suspension between emits: the collector runs only afterwards,
        // as a collector waiting on the main thread does.
        val emitted = (1..200).map { "chunk $it" }
        for (chunk in emitted) {
            assertTrue("tryEmit refused $chunk", flow.tryEmit(chunk to false))
        }
        assertTrue(flow.tryEmit("" to true))
        assertEquals(emitted, received.await().map { it.first })
    }
}
