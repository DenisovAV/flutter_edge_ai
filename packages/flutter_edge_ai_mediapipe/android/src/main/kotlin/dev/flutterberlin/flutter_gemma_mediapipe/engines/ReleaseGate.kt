package dev.flutterberlin.flutter_gemma_mediapipe.engines

import java.util.concurrent.Executor

/**
 * Holds back releasing sessions and engines while a generation runs, and
 * releases them once none does.
 *
 * MediaPipe (tasks-genai 0.10.33) cannot release anything mid-generation:
 * - a session's `close()` throws "Previous invocation still processing" while
 *   an async response is pending. The lock it checks belongs to the engine,
 *   so this holds for every session of that engine;
 * - a session closed during a synchronous `generateResponse()` passes that
 *   check and is deleted under the running native call;
 * - an engine's `close()` deletes it without checking at all.
 *
 * Teardown can come at any of those moments (#590: the activity destroyed
 * mid-response), so every release goes through [retire]. A release that is
 * held back happens when the last generation ends; one that cannot happen
 * because the generation never ends leaks, which beats a native crash.
 */
internal class ReleaseGate(
  private val releaseExecutor: Executor,
  private val warn: (String) -> Unit,
) {
  private val lock = Any()
  private var running = 0
  private val sessions = mutableListOf<InferenceSession>()
  private val engines = mutableListOf<InferenceEngine>()

  /** A generation is starting; [end] must follow exactly once. */
  fun begin() {
    synchronized(lock) { running++ }
  }

  /**
   * A generation is over. MediaPipe reports that on its callback thread, so a
   * release this allows runs on [releaseExecutor], never inside the callback
   * of the session it deletes.
   */
  fun end() {
    val pending = synchronized(lock) {
      if (running > 0) running--
      running == 0 && (sessions.isNotEmpty() || engines.isNotEmpty())
    }
    if (pending) releaseExecutor.execute { releaseIfIdle() }
  }

  /** Releases [session] and [engine] now if nothing is generating, else later. */
  fun retire(session: InferenceSession? = null, engine: InferenceEngine? = null) {
    synchronized(lock) {
      session?.let(sessions::add)
      engine?.let(engines::add)
    }
    releaseIfIdle()
  }

  // Runs under the lock, so no generation can begin in the middle of it.
  private fun releaseIfIdle() {
    synchronized(lock) {
      if (running > 0) return
      // Sessions before the engines they belong to.
      for (session in sessions) {
        runCatching { session.close() }
          .onFailure { warn("Session close failed: ${it.message}") }
      }
      sessions.clear()
      for (engine in engines) {
        runCatching { engine.close() }
          .onFailure { warn("Engine close failed: ${it.message}") }
      }
      engines.clear()
    }
  }
}
