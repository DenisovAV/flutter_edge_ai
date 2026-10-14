import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show MaxLengthEnforcement;
import 'package:flutter_scene/scene.dart'
    show CameraControls, RenderView, SceneView;

import 'embedding_models_screen.dart';
import 'tiny_island/island_hud.dart';
import 'tiny_island/island_suggestions.dart';
import 'tiny_island/island_world.dart';
import 'tiny_island/tiny_island_app_dependencies.dart';
import 'tiny_island/tiny_island_dependencies.dart';
import 'tiny_island/tiny_island_platform.dart';
import 'tiny_island/tiny_island_view_model.dart';

/// Tiny Island: a small 3D scene (flutter_scene) where you tell the character
/// what to do in your own words, and core's Decider over the active
/// EmbeddingGemma 2 picks one of about two hundred actions, or abstains.
///
/// The model is the ACTIVE embedder, chosen on the Embedding Models list
/// (EmbeddingGemma 2 Text 270M is the lightest that works). The scene needs
/// Flutter GPU: on in this app's Android, iOS and macOS manifests; the web
/// renders through flutter_scene's WebGL2 backend. Not offered on Windows
/// and Linux (see `tinyIslandUnsupportedReason`).
class TinyIslandScreen extends StatefulWidget {
  const TinyIslandScreen({super.key, this.dependencies, this.onChooseModel});

  /// Defaults to [tinyIslandAppDependencies]; tests pass fakes.
  final TinyIslandDependencies? dependencies;

  /// Opens the model list. Defaults to pushing [EmbeddingModelsScreen].
  final Future<void> Function(BuildContext context)? onChooseModel;

  @override
  State<TinyIslandScreen> createState() => _TinyIslandScreenState();
}

class _TinyIslandScreenState extends State<TinyIslandScreen> {
  late final TinyIslandDependencies _deps =
      widget.dependencies ?? tinyIslandAppDependencies();
  final IslandWorld _world = IslandWorld();
  late final TinyIslandViewModel _vm = TinyIslandViewModel(_deps, _world);
  final _input = TextEditingController();
  final _inputFocus = FocusNode();

  /// Longer requests are not commands; the cap also keeps an error under
  /// the field on screen.
  static const _maxRequestLength = 200;

  FlutterExceptionHandler? _previousOnError;
  FlutterExceptionHandler? _ourOnError;

  @override
  void initState() {
    super.initState();
    _catchSceneErrors();
    // open() keeps every failure in the view model's state, for the screen.
    unawaited(_vm.open());
    unawaited(_loadWorld());
  }

  /// Builds the scene and compiles its pipelines, so a scene that cannot be
  /// drawn here fails now, visibly, instead of leaving an empty view.
  Future<void> _loadWorld() async {
    try {
      await _world.load();
      if (!mounted || !_world.isLoaded) return;
      await _world.scene.warmUp([
        RenderView(camera: _world.camera),
      ], sliceBudget: const Duration(milliseconds: 50));
      if (!mounted) return;
      _vm.sceneLoaded();
    } catch (e, st) {
      debugPrint('[TinyIsland] the scene did not load: $e\n$st');
      if (!mounted) return;
      _vm.sceneFailed(
        'The 3D scene did not load: $e\n\n${tinyIslandSceneHint()}',
      );
    }
  }

  /// A frame that fails to draw after the scene loaded is reported through
  /// FlutterError, not to this screen. While the screen is up it listens
  /// there too, shows the failure in place of the scene (which stops the
  /// failing frames) and passes the error on unchanged.
  void _catchSceneErrors() {
    final previous = _previousOnError = FlutterError.onError;
    FlutterError.onError = _ourOnError = (details) {
      if (mounted &&
          _vm.sceneReady &&
          _vm.sceneError == null &&
          _isSceneError(details)) {
        // Reported during paint: change state after this frame.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _vm.sceneError != null) return;
          _vm.sceneFailed(
            'The island stopped drawing: ${details.exceptionAsString()}\n\n'
            '${tinyIslandSceneHint()}',
          );
        });
      }
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
  }

  static bool _isSceneError(FlutterErrorDetails details) {
    if (details.library == 'flutter_scene') return true;
    if ('${details.stack}'.contains('package:flutter_scene/')) return true;
    // A release web build has minified stacks; there a failure while
    // painting, with the scene on screen, is taken to be the scene's.
    return kIsWeb &&
        kReleaseMode &&
        details.context?.toDescription() == 'during paint()';
  }

  @override
  void dispose() {
    if (identical(FlutterError.onError, _ourOnError)) {
      FlutterError.onError = _previousOnError;
    }
    _vm.dispose();
    _world.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _chooseModel() async {
    final open = widget.onChooseModel;
    if (open != null) {
      await open(context);
    } else {
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(builder: (_) => const EmbeddingModelsScreen()),
      );
    }
    if (!mounted) return;
    await _vm.open();
  }

  void _send([String? text]) {
    final request = text ?? _input.text;
    // Enter while a request is being decided keeps the typed text for later.
    if (request.trim().isEmpty || !_vm.canSend) return;
    if (text == null) _input.clear();
    unawaited(_vm.submit(request));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Tiny Island'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: ListenableBuilder(
        listenable: _vm,
        builder: (context, _) => Column(
          children: [
            TinyIslandStatusBar(viewModel: _vm, onChooseModel: _chooseModel),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _scene()),
                  if (_vm.sceneReady && _vm.sceneError == null)
                    Positioned.fill(child: _BubbleOverlay(world: _world)),
                  Positioned(
                    left: 8,
                    top: 8,
                    right: 8,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: TinyIslandHud(viewModel: _vm),
                    ),
                  ),
                ],
              ),
            ),
            _suggestionRow(),
            _inputRow(),
          ],
        ),
      ),
    );
  }

  Widget _scene() {
    if (_vm.sceneError case final error?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            error,
            key: const Key('tiny-island-scene-error'),
          ),
        ),
      );
    }
    if (!_vm.sceneReady) {
      return const Center(child: CircularProgressIndicator());
    }
    // Drag to orbit, scroll or pinch to zoom; keys stay with the text field.
    return LayoutBuilder(
      builder: (context, constraints) {
        // Moves the camera only (no widget state): a narrow view backs off
        // so the whole island fits across.
        _world.fitView(constraints.biggest);
        return CameraControls(
          controller: _world.orbit,
          autofocus: false,
          child: SceneView(
            _world.scene,
            // Compiled in _loadWorld, where a failure is shown.
            warmUp: false,
            // 60 is plenty for these animations, and halves the redraws
            // of a 120 Hz display (battery, heat, and on the web a GPU
            // shared with the Decider's WebGPU).
            maxFrameRate: 60,
            onTick: _tick,
          ),
        );
      },
    );
  }

  void _tick(Duration elapsed, double dt) {
    if (_vm.sceneError != null) return;
    try {
      _world.tick(dt);
    } catch (e, st) {
      debugPrint('[TinyIsland] the island stopped: $e\n$st');
      _vm.sceneFailed('The island stopped animating: $e');
    }
  }

  /// Hold to talk: recording runs while the button is held, and the request
  /// is decided when it is let go.
  Widget _micButton() {
    final listening = _vm.listening;
    final enabled = _vm.canSpeak || listening;
    return Tooltip(
      // Not on a long press: the button is held while speaking, and the
      // tooltip would cover it.
      triggerMode: TooltipTriggerMode.manual,
      message: switch (_vm.voiceStatus) {
        TinyIslandVoiceStatus.ready => 'Hold to speak',
        TinyIslandVoiceStatus.preparing => 'Preparing spoken requests...',
        _ => _vm.voiceNote ?? 'Speaking is off',
      },
      child: Listener(
        key: const Key('tiny-island-mic'),
        onPointerDown: (_) => unawaited(_vm.startListening()),
        onPointerUp: (_) => unawaited(_vm.stopListening()),
        onPointerCancel: (_) => unawaited(_vm.stopListening()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: CircleAvatar(
            radius: 20,
            backgroundColor: listening
                ? Colors.red.shade600
                : enabled
                ? const Color(0xFF2a5a8a)
                : Colors.white12,
            child: Icon(
              listening ? Icons.mic : Icons.mic_none,
              color: enabled ? Colors.white : Colors.white38,
            ),
          ),
        ),
      ),
    );
  }

  Widget _suggestionRow() {
    final canSend = _vm.canSend;
    return SizedBox(
      height: 44,
      child: ListView(
        key: const Key('tiny-island-suggestions'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          for (final (i, text) in islandSuggestions.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                key: Key('tiny-island-suggestion-$i'),
                label: Text(text),
                onPressed: canSend ? () => _send(text) : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _inputRow() {
    final ready =
        _vm.status == TinyIslandStatus.ready &&
        _vm.sceneReady &&
        _vm.sceneError == null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('tiny-island-input'),
                controller: _input,
                focusNode: _inputFocus,
                // Disabled until the Decider AND the scene are ready, so no
                // request is sent to an island still loading.
                enabled: ready,
                maxLength: _maxRequestLength,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  _send();
                  _inputFocus.requestFocus();
                },
                decoration: InputDecoration(
                  hintText: _vm.listening
                      ? 'Listening... let go of the mic to send'
                      : ready
                      ? 'e.g. go water the flowers'
                      : _vm.sceneError != null
                      ? 'The island cannot be shown here'
                      : 'Getting the island ready...',
                  counterText: '',
                ),
              ),
            ),
            if (_vm.voiceStatus != TinyIslandVoiceStatus.off) _micButton(),
            IconButton(
              key: const Key('tiny-island-send'),
              icon: const Icon(Icons.send),
              onPressed: _vm.canSend ? _send : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The character's speech bubble, kept over its head as the camera and the
/// character move.
class _BubbleOverlay extends StatelessWidget {
  const _BubbleOverlay({required this.world});

  final IslandWorld world;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) => ValueListenableBuilder<String?>(
          valueListenable: world.bubble,
          builder: (context, text, _) {
            if (text == null) return const SizedBox.shrink();
            return ValueListenableBuilder<int>(
              valueListenable: world.frame,
              builder: (context, _, _) {
                final at = world.camera.worldToScreen(
                  world.bubbleAnchor,
                  constraints.biggest,
                );
                if (at == null) return const SizedBox.shrink();
                return Stack(
                  children: [
                    Positioned(
                      left: at.dx,
                      top: at.dy,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, -1),
                        child: Container(
                          key: const Key('tiny-island-bubble'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: const [
                              BoxShadow(blurRadius: 4, color: Colors.black26),
                            ],
                          ),
                          child: Text(
                            text,
                            style: const TextStyle(
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
