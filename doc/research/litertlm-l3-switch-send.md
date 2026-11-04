# L3: the cost of a session switch on the sending isolate (design note, no change yet)

2026-11-04. Review item I3 of #781: with open sessions as native
conversations, a send to another conversation than the one the executor ran
last saves the outgoing conversation's KV cache and restores this one. The
review traced that into the send call itself:
`send_message_stream` → `Conversation::SendMessageAsync` → `SaveCheckpoint`
(`conversation.cc:860`) → `GetCurrentStep` → `AcquireExecutorWithContextHandler`
(`threaded_execution_manager.cc:1298-1303`), which runs `CloneContext` /
`RestoreContext` when another conversation was current. The Dart client calls
`send_message_stream` on the isolate that sends, which in an app is the UI
isolate.

## Measured (macOS M5 Pro, Gemma 4 E2B, L1 build 287997f2)

`LiteRtLmFfiClient.lastSendCallMicros`, the time `send_message_stream` held
the calling isolate, over turns alternating between two sessions
(`test/ffi/open_sessions_native_test.dart`, median of 20-40 switching sends):

| Backend | `maxTokens` | send, same session | send, switching | max |
|---|---|---|---|---|
| CPU | 4096 | 0.5-0.8 ms | 1.3-1.5 ms | 2.8 ms |
| CPU | 1024 | 0.5 ms | 0.7 ms | 1.0 ms |
| Metal | 4096 | 0.4 ms | 134.9 ms | 135.4 ms |
| Metal | 1024 | 0.5 ms | 34.2 ms | 34.5 ms |

Measured at load average about 4. With other work on the Mac (load about
24) the Metal switching send took 540-620 ms median (up to 1.1 s), with or
without image and audio encoders loaded: the copy competes for the GPU.

On the CPU the switch is not paid in the send call. On Metal it is, and it
scales with the KV size: at 4096 every switching send blocks the UI isolate
for about eight frames. Adreno, Mali, the desktop GPUs and the NPUs are not
measured; `CopyTensorBuffer` keeps a GPU snapshot in the device buffer type
there and allocates FastRPC buffers on the Qualcomm NPU, so they may be slower
or faster than Metal. The device suite
(`example/integration_test/litertlm_open_sessions_test.dart`) prints the same
`send_call_ms` line per backend.

## Proposal (for a decision, not implemented)

Run `send_message_stream` on a spawned isolate, as `conversation_create` and
`rewind_cancelled_turn` already are (`_createConversationOffMainIsolate`,
`_rewindCancelledTurnOffMainIsolate`):

- The proxy callback is a `NativeCallable.listener` owned by the client's
  isolate. Its native function pointer and the stream proxy are plain
  addresses and can be handed to the spawned isolate, which only makes the
  call. The callbacks still arrive on the client's isolate.
- The message, extra context and optional args are allocated by the spawned
  isolate and freed there after the call returns. The stream proxy, the
  callback and the turn registration (`NativeTurnStream`) stay where they are
  today.
- A refused send's status and LiteRT-LM's thread-local last error must be read
  on the spawned isolate (as the create and rewind helpers do), and the
  refused proxy destroyed there or returned for `releaseRefusedStreamProxy`.
- Cost: one `Isolate.run` per send (about 1-3 ms to spawn), paid on every
  turn, including same-session sends that take 0.5 ms today. Spawning only
  when the target conversation is not the executor's current one avoids that.
  The client cannot read the executor's current conversation, but it can
  track the last conversation it sent to.
- The cancel path is unchanged: `conversation_cancel_process` does not take
  the executor and stays on the client's isolate.

Decide after the device runs: if the Adreno/Mali `send_call_ms` switching
median is above a frame, do it in L3 or a follow-up before PR 13; otherwise
document the Metal cost next to `openSession` (done in the litertlm README)
and leave the send where it is.
