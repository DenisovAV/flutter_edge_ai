import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show CameraControls, SceneView;

import 'embedding_models_screen.dart';
import 'tiny_island/island_hud.dart';
import 'tiny_island/island_world.dart';
import 'tiny_island/tiny_island_app_dependencies.dart';
import 'tiny_island/tiny_island_dependencies.dart';
import 'tiny_island/tiny_island_view_model.dart';

/// Tiny Island: a small 3D scene (flutter_scene) where you tell the character
/// what to do in your own words, and an on-device Decider — EmbeddingGemma 2
/// — picks one of about two hundred actions, or abstains.
///
/// The model is the ACTIVE embedder, chosen on the Embedding Models list
/// (EmbeddingGemma 2 Text 270M is the lightest that works). The scene needs
/// Flutter GPU: on by default in this app's Android, iOS and macOS manifests;
/// pass `--enable-flutter-gpu` on Windows and Linux. The web renders through
/// flutter_scene's own WebGL2 backend.
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
  bool _sceneReady = false;
  String? _sceneError;

  /// Requests to try, from the catalog and outside it.
  static const _suggestions = [
    'walk over to the well',
    'open the treasure chest',
    'water the flowers',
    'turn on the lamp',
    'make it night',
    'light the campfire',
    'make it rain',
    'sit on the bench',
    'dance for me',
    'show me the house up close',
    'сделай закат',
    'geh zum Baum',
    'what is the capital of France?',
  ];

  @override
  void initState() {
    super.initState();
    // open() keeps every failure in the view model's state, for the screen.
    unawaited(_vm.open());
    unawaited(_loadWorld());
  }

  Future<void> _loadWorld() async {
    try {
      await _world.load();
      if (!mounted) return;
      setState(() => _sceneReady = true);
    } catch (e, st) {
      debugPrint('[TinyIsland] the scene did not load: $e\n$st');
      if (!mounted) return;
      setState(() {
        _sceneError =
            'The 3D scene did not load: $e\n\n'
            '${kIsWeb ? 'The browser needs WebGL2.' : 'flutter_scene renders through Flutter GPU: run with --enable-flutter-gpu (Windows, Linux), or keep the FLTEnableFlutterGPU / EnableFlutterGPU flag in the app manifest (iOS, macOS, Android).'}';
      });
    }
  }

  @override
  void dispose() {
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
    if (request.trim().isEmpty) return;
    _input.clear();
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
                  if (_sceneReady)
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
    if (_sceneError case final error?) {
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
    if (!_sceneReady) {
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
            // Compiles the pipelines before the first frame shows, instead
            // of stalling the first frames that draw each material.
            warmUp: true,
            onTick: (elapsed, dt) => _world.tick(dt),
          ),
        );
      },
    );
  }

  Widget _suggestionRow() {
    final ready = _vm.status == TinyIslandStatus.ready;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          for (final (i, text) in _suggestions.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                key: Key('tiny-island-suggestion-$i'),
                label: Text(text),
                onPressed: ready && !_vm.deciding ? () => _send(text) : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _inputRow() {
    final ready = _vm.status == TinyIslandStatus.ready;
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
                enabled: ready,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  _send();
                  _inputFocus.requestFocus();
                },
                decoration: const InputDecoration(
                  hintText: 'e.g. go water the flowers',
                ),
              ),
            ),
            IconButton(
              key: const Key('tiny-island-send'),
              icon: const Icon(Icons.send),
              onPressed: ready && !_vm.deciding ? _send : null,
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
