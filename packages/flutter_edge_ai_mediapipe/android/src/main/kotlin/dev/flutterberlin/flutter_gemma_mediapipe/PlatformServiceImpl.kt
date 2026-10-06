package dev.flutterberlin.flutter_gemma_mediapipe

import android.content.Context
import android.util.Log

import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executors
import kotlinx.coroutines.*

import dev.flutterberlin.flutter_gemma_mediapipe.engines.*

internal class PlatformServiceImpl(
  val context: Context
) : PlatformService, EventChannel.StreamHandler {
  companion object {
    private const val TAG = "FlutterEdgeAiMediaPipePlugin"

    // Process-wide: a release held back by one engine instance may come due
    // after that instance (and its coroutine scope) is gone.
    private val RELEASES = Executors.newSingleThreadExecutor { task ->
      Thread(task, "flutter_edge_ai_mediapipe-release").apply { isDaemon = true }
    }
  }

  // Every session and engine is released through this, never closed directly:
  // MediaPipe throws or crashes when one is released mid-generation (#590).
  private val gate = ReleaseGate(RELEASES) { Log.w(TAG, it) }
  private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
  private var eventSink: EventChannel.EventSink? = null
  private var streamJob: kotlinx.coroutines.Job? = null  // Track stream collection job
  private val engineLock = Any()  // Lock for thread-safe engine access

  // NEW: Use InferenceEngine abstraction instead of InferenceModel
  @Volatile private var engine: InferenceEngine? = null
  @Volatile private var session: InferenceSession? = null

  // Multi-session (.task): concurrently-open sessions keyed by sessionId.
  // The singleton `session` above stays the legacy path; these are the
  // openSession() sessions. Generation is serialized in Dart (a Mutex), so
  // at most one of these streams at a time — the shared event channel stays
  // unambiguous.
  private val sessionMap = mutableMapOf<Long, InferenceSession>()
  private val sessionMapLock = Any()

  // RAG components
  // 0.15.2: embedding implementation moved to Dart (LitertEmbeddingModel
  // via dart:ffi). The pigeon contract below is kept for ABI continuity
  // but the Dart side never calls into it.

  // Runs inside FlutterEngine.destroy(), possibly while a response is still
  // generating. Nothing here may throw, or the engine teardown stops short and
  // the exception escapes Activity.onDestroy (#590). Generation is cancelled;
  // the gate releases the sessions and the engine once it has stopped.
  fun cleanup() {
    scope.cancel()
    streamJob?.cancel()
    streamJob = null
    synchronized(engineLock) {
      val sessions = synchronized(sessionMapLock) {
        sessionMap.values.toList().also { sessionMap.clear() }
      }
      for (s in listOfNotNull(session) + sessions) {
        s.cancelGeneration()
        gate.retire(session = s)
      }
      gate.retire(engine = engine)
      session = null
      engine = null
    }
    // 0.15.2: embedding lifetime managed by Dart (LitertEmbeddingModel).
  }

  override fun createModel(
    maxTokens: Long,
    modelPath: String,
    loraRanks: List<Long>?,
    preferredBackend: PreferredBackend?,
    maxNumImages: Long?,
    supportAudio: Boolean?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        // Build configuration first (before touching state)
        val config = EngineConfig(
          modelPath = modelPath,
          maxTokens = maxTokens.toInt(),
          supportedLoraRanks = loraRanks?.map { it.toInt() },
          preferredBackend = preferredBackend,
          maxNumImages = maxNumImages?.toInt(),
          supportAudio = supportAudio,
        )

        // Create and initialize new engine BEFORE clearing old state
        // This ensures we don't leave state inconsistent on failure
        val newEngine = EngineFactory.createFromModelPath(modelPath, context)
        newEngine.initialize(config)

        // Only now clear old state and swap in new engine (thread-safe)
        synchronized(engineLock) {
          // Cancel stale stream collector before replacing engine
          streamJob?.cancel()
          streamJob = null
          session?.cancelGeneration()
          gate.retire(session = session, engine = engine)
          session = null
          engine = newEngine
        }

        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeModel(callback: (Result<Unit>) -> Unit) {
    synchronized(engineLock) {
      try {
        val sessions = synchronized(sessionMapLock) {
          sessionMap.values.toList().also { sessionMap.clear() }
        }
        for (s in listOfNotNull(session) + sessions) {
          s.cancelGeneration()
          gate.retire(session = s)
        }
        gate.retire(engine = engine)
        session = null
        engine = null
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun createSession(
    temperature: Double,
    randomSeed: Long,
    topK: Long,
    topP: Double?,
    loraPath: String?,
    enableVisionModality: Boolean?,
    enableAudioModality: Boolean?,
    systemInstruction: String?,
    enableThinking: Boolean?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        synchronized(engineLock) {
          val currentEngine = engine
            ?: throw IllegalStateException("Inference model is not created")

          val config = SessionConfig(
            temperature = temperature.toFloat(),
            randomSeed = randomSeed.toInt(),
            topK = topK.toInt(),
            topP = topP?.toFloat(),
            loraPath = loraPath,
            enableVisionModality = enableVisionModality,
            enableAudioModality = enableAudioModality,
            systemInstruction = systemInstruction,
            enableThinking = enableThinking ?: false,
          )

          gate.retire(session = session)
          session = currentEngine.createSession(config)
        }
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeSession(callback: (Result<Unit>) -> Unit) {
    synchronized(engineLock) {
      try {
        gate.retire(session = session)
        session = null
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun sizeInTokens(prompt: String, callback: (Result<Long>) -> Unit) {
    scope.launch {
      try {
        val currentSession = session
          ?: throw IllegalStateException("Session not created")
        val size = currentSession.sizeInTokens(prompt)
        callback(Result.success(size.toLong()))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addQueryChunk(prompt: String, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        val currentSession = session
          ?: throw IllegalStateException("Session not created")
        currentSession.addQueryChunk(prompt)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addImage(imageBytes: ByteArray, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        val currentSession = session
          ?: throw IllegalStateException("Session not created")
        currentSession.addImage(imageBytes)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addAudio(audioBytes: ByteArray, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        session?.addAudio(audioBytes) ?: throw IllegalStateException("Session not created")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun generateResponse(callback: (Result<String>) -> Unit) {
    scope.launch {
      try {
        val currentSession = session
          ?: throw IllegalStateException("Session not created")
        gate.begin()
        val result = try {
          currentSession.generateResponse()
        } finally {
          gate.end()
        }
        callback(Result.success(result))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun generateResponseAsync(callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        val currentSession = session
          ?: throw IllegalStateException("Session not created")
        gate.begin()
        currentSession.generateResponseAsync(onSettled = gate::end)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun stopGeneration(callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        val currentSession = session
          ?: throw IllegalStateException("Session not created")
        currentSession.cancelGeneration()
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  // === Multi-session (.task) — session-scoped twins keyed by sessionId. ===
  // The legacy singleton methods above are untouched; these address one of N
  // concurrently-open sessions held in [sessionMap].

  private fun requireSession(sessionId: Long): InferenceSession =
    synchronized(sessionMapLock) {
      sessionMap[sessionId]
        ?: throw IllegalStateException("Session $sessionId not found")
    }

  override fun createSessionForId(
    sessionId: Long,
    temperature: Double,
    randomSeed: Long,
    topK: Long,
    topP: Double?,
    loraPath: String?,
    enableVisionModality: Boolean?,
    enableAudioModality: Boolean?,
    systemInstruction: String?,
    enableThinking: Boolean?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        val config = SessionConfig(
          temperature = temperature.toFloat(),
          randomSeed = randomSeed.toInt(),
          topK = topK.toInt(),
          topP = topP?.toFloat(),
          loraPath = loraPath,
          enableVisionModality = enableVisionModality,
          enableAudioModality = enableAudioModality,
          systemInstruction = systemInstruction,
          enableThinking = enableThinking ?: false,
        )
        // Build the session OUTSIDE the map lock — createSession can be slow.
        val currentEngine = synchronized(engineLock) {
          engine ?: throw IllegalStateException("Inference model is not created")
        }
        val newSession = currentEngine.createSession(config)
        synchronized(sessionMapLock) {
          sessionMap[sessionId]?.let { gate.retire(session = it) }
          sessionMap[sessionId] = newSession
        }
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeSessionId(sessionId: Long, callback: (Result<Unit>) -> Unit) {
    try {
      synchronized(sessionMapLock) {
        sessionMap.remove(sessionId)?.let { gate.retire(session = it) }
      }
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun sizeInTokensForSession(
    sessionId: Long,
    prompt: String,
    callback: (Result<Long>) -> Unit
  ) {
    scope.launch {
      try {
        callback(Result.success(requireSession(sessionId).sizeInTokens(prompt).toLong()))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addQueryChunkToSession(
    sessionId: Long,
    prompt: String,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        requireSession(sessionId).addQueryChunk(prompt)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addImageToSession(
    sessionId: Long,
    imageBytes: ByteArray,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        requireSession(sessionId).addImage(imageBytes)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addAudioToSession(
    sessionId: Long,
    audioBytes: ByteArray,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        requireSession(sessionId).addAudio(audioBytes)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun generateResponseForSession(
    sessionId: Long,
    callback: (Result<String>) -> Unit
  ) {
    scope.launch {
      try {
        val s = requireSession(sessionId)
        gate.begin()
        val result = try {
          s.generateResponse()
        } finally {
          gate.end()
        }
        callback(Result.success(result))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun generateResponseAsyncForSession(
    sessionId: Long,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        val s = requireSession(sessionId)
        val mpSession = s as? dev.flutterberlin.flutter_gemma_mediapipe.engines.mediapipe.MediaPipeSession
          ?: throw IllegalStateException(
            "Session $sessionId does not support tagged async streaming")
        // Tag every chunk with sessionId and push over the shared event
        // channel directly (NOT via endOfStream — that would close the channel
        // for other sessions). Dart demuxes by the sessionId key.
        try {
          gate.begin()
          mpSession.generateResponseAsyncTagged(
            onResult = { result, done ->
              val payload = mapOf(
                "partialResult" to result,
                "done" to done,
                "sessionId" to sessionId,
              )
              scope.launch(Dispatchers.Main) { eventSink?.success(payload) }
            },
            onSettled = gate::end,
          )
        } catch (e: Exception) {
          // Surface a generation-time error as a TAGGED DATA event (not an
          // EventChannel error, which would hit every session's listener and
          // drop the sessionId). Dart demuxes it and closes only this session.
          val errPayload = mapOf(
            "code" to "ERROR",
            "message" to (e.message ?: "generation failed"),
            "sessionId" to sessionId,
          )
          scope.launch(Dispatchers.Main) { eventSink?.success(errPayload) }
        }
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun stopGenerationForSession(
    sessionId: Long,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        requireSession(sessionId).cancelGeneration()
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    // Cancel previous stream collection to prevent orphaned coroutines
    streamJob?.cancel()
    eventSink = events

    synchronized(engineLock) {
      val currentEngine = engine ?: return

      streamJob = scope.launch {
        launch {
          currentEngine.partialResults.collect { (text, done) ->
            val payload = mapOf("partialResult" to text, "done" to done)
            withContext(Dispatchers.Main) {
              events?.success(payload)
              if (done) {
                events?.endOfStream()
              }
            }
          }
        }

        launch {
          currentEngine.errors.collect { error ->
            withContext(Dispatchers.Main) {
              events?.error("ERROR", error.message, null)
            }
          }
        }
      }
    }
  }

  override fun onCancel(arguments: Any?) {
    streamJob?.cancel()
    streamJob = null
    eventSink = null
  }

  // 0.15.2: embedding pigeon methods dropped from PlatformService contract.
  // Dart now talks to LiteRT C API directly via dart:ffi
  // (lib/core/litert/litert_embedding_model.dart).
}
