import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:record/record.dart';

import 'model.dart';

/// A chat that shows the reply as it is generated — and, from this step on,
/// takes a question spoken into the microphone as well as a typed one.
///
/// `generateChatResponseAsync` emits one [ModelResponse] per decoded chunk,
/// so the first words appear long before the last one is computed.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.model,
    required this.onModelRemoved,
  });

  final ModelChoice model;

  /// Lets the gate send the app back to the download screen.
  final VoidCallback onModelRemoved;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _turns = <_Turn>[];

  InferenceModel? _inference;
  InferenceChat? _chat;
  bool _busy = false;
  Object? _loadError;

  /// Turns 16 kHz mono PCM into text.
  SpeechRecognizer? _stt;

  final _recorder = AudioRecorder();
  bool _listening = false;
  bool _transcribing = false;

  /// The recording in progress: the bytes so far, the end of the stream that
  /// delivers them, and the timer that stops it at the model's window.
  BytesBuilder? _pcm;
  Completer<void>? _micDone;
  Timer? _cutoff;

  /// Set while `startStream` is still opening the microphone, so a second tap
  /// that lands in that gap waits for it instead of stopping nothing.
  Future<void>? _micStarting;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // maxTokens is the CONTEXT WINDOW — prompt + history + reply share it.
      // It is NOT a reply-length cap; for that, pass maxOutputTokens below.
      final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      // Hold the runtime before opening a chat on it: `createChat` can throw,
      // and a model this page never stored is a model `dispose` can never
      // close. A page that is already gone holds nothing, so it closes it here.
      if (!mounted) {
        await inference.close();
        return;
      }
      setState(() => _inference = inference);

      final chat = await inference.createChat(
        modelType: widget.model.modelType,
        maxOutputTokens: 256,
      );
      // The same guard, one call later and for the same reason: a chat this
      // page never stored is a native session `dispose` can never close.
      if (!mounted) {
        await chat.close();
        return;
      }
      setState(() => _chat = chat);

      // The files are already here — the gate made sure of that — so this
      // downloads nothing. What it does is make moonshine the ACTIVE speech
      // model again: that choice lives in memory and does not survive a
      // restart, and `getActiveStt()` throws without it.
      await FlutterEdgeAi.installStt()
          .modelFromNetwork(Moonshine.modelUrl)
          .tokenizerFromNetwork(Moonshine.tokenizerUrl)
          .ofType(SttModelType.moonshine)
          .install();
      final stt = await FlutterEdgeAi.getActiveStt();
      if (!mounted) {
        await stt.close();
        return;
      }
      setState(() => _stt = stt);
    } catch (error) {
      // Loading is the likeliest thing to fail on a real device: a forgotten
      // engine package, too little memory, a half-written model file. Show it
      // instead of sitting on the progress bar forever.
      if (mounted) setState(() => _loadError = error);
    }
  }

  void _retryLoad() {
    setState(() => _loadError = null);
    _load();
  }

  /// Sends [spoken] if given, otherwise whatever is in the text field. Both
  /// arrive at the model the same way: as text. The model never hears audio.
  Future<void> _send([String? spoken]) async {
    final chat = _chat;
    final text = (spoken ?? _input.text).trim();
    if (chat == null || text.isEmpty || _busy) return;

    setState(() {
      _turns
        ..add(_Turn(text, fromUser: true))
        // The reply starts empty and grows as chunks arrive.
        ..add(_Turn('', fromUser: false));
      if (spoken == null) _input.clear();
      _busy = true;
    });

    try {
      await chat.addQueryChunk(Message.text(text: text, isUser: true));

      final buffer = StringBuffer();
      await for (final chunk in chat.generateChatResponseAsync()) {
        // Each TextResponse carries only the NEW text, not the whole reply
        // so far — append, never replace.
        if (chunk is TextResponse) {
          buffer.write(chunk.token);
          if (!mounted) return;
          setState(
            () => _turns[_turns.length - 1] = _Turn(
              buffer.toString(),
              fromUser: false,
            ),
          );
        }
      }
    } catch (error) {
      // The half-written reply becomes the error, so the empty bubble never
      // just sits there. The chat's own history now holds a user turn the model
      // never answered; a production app would reset it with `clearHistory`.
      if (mounted) {
        setState(
          () => _turns[_turns.length - 1] = _Turn('⚠️ $error', fromUser: false),
        );
      }
    } finally {
      // `_busy` is what disables the composer, so clearing it belongs in
      // `finally` — a failed generation must not lock the app.
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One tap starts the microphone, the next one stops it and transcribes.
  Future<void> _toggleMic() async {
    // `_listening` turns true only once the microphone is open. A tap that
    // lands while it is still opening is a stop too, not a second start.
    if (_listening || _opening) {
      await _stopListening();
    } else {
      await _openMic();
    }
  }

  Future<void> _openMic() async {
    _opening = true;
    try {
      await (_micStarting = _startListening());
    } finally {
      _opening = false;
    }
  }

  Future<void> _startListening() async {
    if (_stt == null || _busy || _transcribing) return;
    // Asks the OS the first time; `false` means the user said no.
    if (!await _recorder.hasPermission()) {
      _say('Microphone permission was denied.');
      return;
    }

    // The exact format `transcribe` takes: 16 kHz, one channel, 16-bit
    // little-endian samples, no header. Asking the recorder for it means there
    // is nothing to convert — no WAV to parse, no resampling.
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    final pcm = BytesBuilder(copy: false);
    final done = Completer<void>();
    stream.listen(pcm.add, onDone: done.complete, onError: done.completeError);
    _pcm = pcm;
    _micDone = done;

    // moonshine's window is five seconds and anything past it is dropped, so
    // stop there rather than record words that can never be transcribed.
    _cutoff = Timer(Moonshine.maxRecording, _stopListening);
    if (mounted) setState(() => _listening = true);
  }

  Future<void> _stopListening() async {
    await _micStarting;
    if (!_listening) return;
    _cutoff?.cancel();
    setState(() {
      _listening = false;
      _transcribing = true;
    });

    try {
      // `stop` closes the stream; waiting for its end means the last chunk
      // is in the buffer before we read it.
      await _recorder.stop();
      await _micDone?.future;
      final audio = _pcm!.takeBytes();

      final text = (await _stt!.transcribe(audio)).trim();
      if (!mounted) return;
      setState(() => _transcribing = false);
      if (text.isEmpty) {
        _say("Didn't catch that — try again a little closer to the mic.");
        return;
      }
      await _send(text);
    } catch (error) {
      if (mounted) {
        setState(() => _transcribing = false);
        _say('Speech recognition failed: $error');
      }
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Frees the disk. Close the runtime first — the file is mapped while a
  /// model is open, and deleting it underneath the engine is a crash waiting
  /// to happen.
  Future<void> _removeModel() async {
    try {
      await _inference?.close();
      // Inside `setState`: dropping the chat has to repaint, or the screen
      // keeps showing an enabled composer over a runtime that is gone.
      if (mounted) {
        setState(() {
          _inference = null;
          _chat = null;
        });
      }
      await FlutterEdgeAi.uninstallModel(widget.model.fileName);
      if (mounted) widget.onModelRemoved();
    } catch (error) {
      // Deleting can fail too — a missing install record, a file the OS still
      // holds. Show it the way a failed load is shown, and drop the chat with
      // it: a `close()` that threw leaves `_chat` non-null, and "The model did
      // not load." over a working composer is a lie.
      if (mounted) {
        setState(() {
          _chat = null;
          _loadError = error;
        });
      }
    }
  }

  @override
  void dispose() {
    // Sessions and models hold native memory — always close them. `dispose`
    // cannot await, so the future is dropped on purpose, and caught so a
    // failing native teardown does not escape as an unhandled async error.
    _inference?.close().catchError((Object _) {});
    _stt?.close().catchError((Object _) {});
    _cutoff?.cancel();
    _recorder.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _chat != null;
    final error = _loadError;
    final canListen = _stt != null && !_busy && !_transcribing;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.model.label),
        actions: [
          IconButton(
            tooltip: 'Delete the downloaded model',
            // Not while the model is still opening: deleting the file
            // underneath an in-flight `getActiveModel()` is the crash the
            // comment on `_removeModel` warns about.
            onPressed: _busy || (!ready && error == null) ? null : _removeModel,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          if (error != null)
            _LoadFailed(error: error, onRetry: _retryLoad)
          else if (!ready)
            const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _turns.length,
              itemBuilder: (context, i) => _Bubble(turn: _turns[i]),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: ready && !_busy,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: _listening
                            ? 'Listening… tap the mic again to stop'
                            : _transcribing
                            ? 'Transcribing…'
                            : ready
                            ? 'Ask something, or tap the mic'
                            : error != null
                            ? 'No model loaded'
                            : 'Loading the model…',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: _listening ? 'Stop and send' : 'Speak',
                    onPressed: _listening || canListen ? _toggleMic : null,
                    icon: Icon(_listening ? Icons.stop : Icons.mic),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: ready && !_busy ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the loading bar when the model could not be opened.
class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text('The model did not load.\n$error', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

class _Turn {
  const _Turn(this.text, {required this.fromUser});
  final String text;
  final bool fromUser;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: turn.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: turn.fromUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(turn.text),
      ),
    );
  }
}
