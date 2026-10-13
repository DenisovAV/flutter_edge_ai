import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show Size;

import 'package:flutter/animation.dart' show Curves;
import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'island_catalog.dart';
import 'island_stage.dart';
import 'island_vocabulary.dart';

/// Tiny Island in 3D: the flutter_scene graph (island, things, the
/// character, sky, lights, rain), and a short script for every action.
///
/// Not a widget: the screen shows [scene] in a `SceneView`, forwards its
/// ticks to [tick], and overlays [bubble] at [bubbleAnchor]. Actions queue:
/// each starts when the one before it has finished.
///
/// Models: Kenney's CC0 kits (see assets/island/LICENSE.md), converted to
/// `.fsceneb` at build time by hook/build.dart and loaded by source path.
/// The house, the well, the island and the effects are built from
/// flutter_scene's primitives.
final class IslandWorld implements IslandStage {
  IslandWorld({this.onLog = _print});

  /// Where load-time facts go (the clips found, what failed to load).
  final void Function(String message) onLog;

  static void _print(String message) => debugPrint('[TinyIsland] $message');

  late final Scene scene;
  late final Node _cameraNode;
  late final OrbitCameraController orbit;

  /// Text above the character's head; null when there is none.
  final ValueNotifier<String?> bubble = ValueNotifier(null);

  /// Bumped every frame, for overlays that follow the scene.
  final ValueNotifier<int> frame = ValueNotifier(0);

  bool _loaded = false;
  bool _disposed = false;
  bool get isLoaded => _loaded;

  /// The camera the scene renders through (for projecting overlays).
  Camera get camera => _cameraNode.getComponent<CameraComponent>()!.toCamera();

  /// The world point the bubble hangs from.
  vm.Vector3 get bubbleAnchor =>
      _actor.position + vm.Vector3(0, _characterHeight + 0.45, 0);

  // ---------------------------------------------------------------- loading

  static const _models = 'assets/island/models';
  static const _characterScale = 1.5;
  static const _characterHeight = 0.671 * _characterScale;
  static final _up = vm.Vector3(0, 1, 0);

  late final Node _actor;
  final Map<String, ({AnimationClip clip, double length})> _clips = {};
  final Map<IslandThing, _Thing> _things = {};
  late final _House _house;
  late final _Lamp _lamp;
  late final _Fire _fire;
  late final _Well _well;
  late final Node _chest;
  late final Node _flowerBed;
  final List<Node> _flowers = [];
  final List<Node> _sprouts = [];
  final List<Node> _droplets = [];
  final List<Node> _coins = [];
  late final InstancedMesh _rain;
  late final Node _rainNode;
  final List<vm.Vector3> _rainDrops = [];
  late final GradientSkySource _sky;
  late final DirectionalLight _sun;

  /// Builds the scene. Throws when Flutter GPU is not available (the native
  /// platforms need it turned on) or a model does not load.
  Future<void> load() async {
    await Scene.initializeStaticResources();
    if (_disposed) return;
    scene = Scene();
    _buildSkyAndLight();
    _buildIsland();
    _house = _buildHouse(vm.Vector3(-2.6, 0, 2.7));
    _well = await _buildWell(vm.Vector3(3.7, 0, -0.4));
    _fire = await _buildCampfire(vm.Vector3(0.1, 0, -2.3));
    _lamp = await _buildLamp(vm.Vector3(1.4, 0, 3.2));
    await _buildThings();
    await _buildDecor();
    await _buildCharacter();
    _buildEffects();
    _buildCamera();
    _loaded = true;
  }

  Future<Node> _model(
    String name, {
    required vm.Vector3 at,
    double scale = 1,
    double yaw = 0,
    Node? parent,
  }) async {
    final model = await loadScene('$_models/$name.glb');
    final holder = Node(name: name)
      ..position = at
      ..rotation = vm.Quaternion.axisAngle(_up, yaw)
      ..scale = vm.Vector3.all(scale);
    holder.add(model);
    (parent ?? scene.root).add(holder);
    return holder;
  }

  static PhysicallyBasedMaterial _matte(
    double r,
    double g,
    double b, {
    double roughness = 0.85,
    double metallic = 0,
  }) => PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(r, g, b, 1)
    ..roughnessFactor = roughness
    ..metallicFactor = metallic;

  Node _box(
    vm.Vector3 size,
    vm.Vector3 at,
    Material material, {
    Node? parent,
    String name = '',
  }) {
    final node = Node(name: name, mesh: Mesh(CuboidGeometry(size), material))
      ..position = at;
    (parent ?? scene.root).add(node);
    return node;
  }

  void _buildSkyAndLight() {
    _sky = GradientSkySource();
    scene.skybox = Skybox(_sky);
    _sun = DirectionalLight(castsShadow: true, shadowSoftness: 0.12);
    scene.directionalLight = _sun;
    _applySky(_skies[_SkyKind.day]!, wetness: 0);
  }

  void _buildIsland() {
    // Water, sand and grass: stacked so no two surfaces share a plane.
    scene.root.add(
      Node(
        name: 'water',
        mesh: Mesh(
          DiscGeometry(radius: 60, segments: 64),
          _matte(0.05, 0.3, 0.55, roughness: 0.55),
        ),
      )..position = vm.Vector3(0, -0.14, 0),
    );
    scene.root.add(
      Node(
        name: 'sand',
        mesh: Mesh(
          CylinderGeometry(
            bottomRadius: 5.8,
            topRadius: 5.4,
            height: 0.4,
            radialSegments: 48,
          ),
          _matte(0.93, 0.83, 0.6),
        ),
      )..position = vm.Vector3(0, -0.23, 0),
    );
    scene.root.add(
      Node(
        name: 'grass',
        mesh: Mesh(
          CylinderGeometry(
            bottomRadius: 4.95,
            topRadius: 4.8,
            // Its hidden underside at -0.137: off the -0.05 x scale planes
            // the kit models' bases sit on.
            height: 0.137,
            radialSegments: 48,
          ),
          _matte(0.36, 0.66, 0.3),
        ),
      )..position = vm.Vector3(0, -0.0685, 0),
    );
  }

  _House _buildHouse(vm.Vector3 at) {
    final house = Node(name: 'house')..position = at;
    scene.root.add(house);
    const width = 2.4, depth = 2.0, height = 1.6;
    final walls = _matte(0.95, 0.9, 0.78);
    _box(
      vm.Vector3(width, height, depth),
      vm.Vector3(0, height / 2, 0),
      walls,
      parent: house,
      name: 'walls',
    );
    // Gable roof: two wedges back to back, ridge along X, a little above the
    // walls so the roof's underside never shares the walls' top plane.
    final roof = _matte(0.75, 0.25, 0.2);
    const run = depth / 2 + 0.2;
    house.add(
      Node(
        name: 'roof-front',
        mesh: Mesh(WedgeGeometry(vm.Vector3(width + 0.4, 0.95, run)), roof),
      )..position = vm.Vector3(0, height + 0.01, -run / 2),
    );
    house.add(
      Node(
          name: 'roof-back',
          mesh: Mesh(WedgeGeometry(vm.Vector3(width + 0.4, 0.95, run)), roof),
        )
        ..position = vm.Vector3(0, height + 0.01, run / 2)
        ..rotation = vm.Quaternion.axisAngle(_up, math.pi),
    );
    _box(
      vm.Vector3(0.3, 0.7, 0.3),
      vm.Vector3(-0.7, height + 0.75, 0.35),
      _matte(0.55, 0.5, 0.48),
      parent: house,
      name: 'chimney',
    );
    // The door hangs from a hinge node on its left edge, a few millimetres
    // off the wall.
    const front = -depth / 2 - 0.035;
    final hinge = Node(name: 'door-hinge')
      ..position = vm.Vector3(0.05, 0, front);
    house.add(hinge);
    _box(
      vm.Vector3(0.62, 1.12, 0.06),
      vm.Vector3(0.31, 0.56, 0),
      _matte(0.5, 0.3, 0.15),
      parent: hinge,
      name: 'door',
    );
    final glass = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.25, 0.33, 0.45, 1)
      ..roughnessFactor = 0.3
      ..metallicFactor = 0;
    for (final (x, z, yaw) in [
      (-0.65, front, 0.0),
      (width / 2 + 0.025, 0.0, math.pi / 2),
      (-width / 2 - 0.025, 0.0, math.pi / 2),
    ]) {
      house.add(
        Node(
            name: 'window',
            mesh: Mesh(CuboidGeometry(vm.Vector3(0.5, 0.42, 0.05)), glass),
          )
          ..position = vm.Vector3(x, 1.0, z)
          ..rotation = vm.Quaternion.axisAngle(_up, yaw),
      );
    }
    final thing = _Thing(
      node: house,
      focus: at + vm.Vector3(0, 1.0, 0),
      approach: at + vm.Vector3(0.35, 0, front - 0.75),
      radius: 1.45,
      halfExtents: vm.Vector3(1.4, 1.3, 1.2),
    );
    _things[IslandThing.house] = thing;
    return _House(hinge: hinge, windows: glass, inside: at.clone());
  }

  Future<_Well> _buildWell(vm.Vector3 at) async {
    final well = Node(name: 'well')..position = at;
    scene.root.add(well);
    final stone = _matte(0.6, 0.6, 0.62);
    well.add(
      Node(
        name: 'well-ring',
        mesh: Mesh(
          CylinderGeometry(bottomRadius: 0.62, topRadius: 0.6, height: 0.7),
          stone,
        ),
      )..position = vm.Vector3(0, 0.35, 0),
    );
    final water = _matte(0.08, 0.2, 0.35, roughness: 0.15)..depthLayer = 1;
    well.add(
      Node(name: 'well-water', mesh: Mesh(DiscGeometry(radius: 0.5), water))
        ..position = vm.Vector3(0, 0.705, 0),
    );
    final wood = _matte(0.45, 0.3, 0.18);
    for (final x in [-0.55, 0.55]) {
      _box(
        vm.Vector3(0.1, 1.35, 0.1),
        vm.Vector3(x, 0.675 + 0.02, 0),
        wood,
        parent: well,
      );
    }
    _box(
      vm.Vector3(1.25, 0.08, 0.08),
      vm.Vector3(0, 1.3, 0),
      wood,
      parent: well,
    );
    well.add(
      Node(
          name: 'well-roof',
          mesh: Mesh(
            CylinderGeometry(
              bottomRadius: 0.95,
              topRadius: 0,
              height: 0.5,
              radialSegments: 4,
            ),
            _matte(0.75, 0.25, 0.2),
          ),
        )
        ..position = vm.Vector3(0, 1.6, 0)
        ..rotation = vm.Quaternion.axisAngle(_up, math.pi / 4),
    );
    final bucket = await _model(
      'bucket',
      at: vm.Vector3(0, 0.95, 0),
      scale: 1.6,
      parent: well,
    );
    _things[IslandThing.well] = _Thing(
      node: well,
      focus: at + vm.Vector3(0, 0.7, 0),
      approach: at + _toward(at, vm.Vector3.zero(), 1.15),
      radius: 0.8,
      halfExtents: vm.Vector3(0.8, 1.0, 0.8),
    );
    return _Well(bucket: bucket, rest: bucket.position);
  }

  Future<_Fire> _buildCampfire(vm.Vector3 at) async {
    // Lifted 4 mm: the stones' undersides would share the grass's plane.
    final node = await _model(
      'campfire_stones',
      at: at + vm.Vector3(0, 0.004, 0),
      scale: 2.2,
    );
    final flame = Node(name: 'flame')..position = at + vm.Vector3(0, 0.08, 0);
    final outer = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(1, 0.45, 0.1, 1)
      ..emissiveFactor = vm.Vector4(1, 0.4, 0.08, 1)
      ..emissiveStrength = 6;
    final inner = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(1, 0.85, 0.3, 1)
      ..emissiveFactor = vm.Vector4(1, 0.8, 0.25, 1)
      ..emissiveStrength = 8;
    flame.add(
      Node(
        mesh: Mesh(
          CylinderGeometry(bottomRadius: 0.2, topRadius: 0, height: 0.55),
          outer,
        ),
      )..position = vm.Vector3(0, 0.275, 0),
    );
    flame.add(
      Node(
        mesh: Mesh(
          CylinderGeometry(bottomRadius: 0.11, topRadius: 0, height: 0.36),
          inner,
        ),
      )..position = vm.Vector3(0, 0.2, 0.0),
    );
    final light = PointLight(
      color: vm.Vector3(1, 0.55, 0.25),
      intensity: 0,
      range: 5,
    );
    flame.addComponent(PointLightComponent(light));
    flame.visible = false;
    scene.root.add(flame);
    _things[IslandThing.campfire] = _Thing(
      node: node,
      focus: at + vm.Vector3(0, 0.3, 0),
      approach: at + _toward(at, vm.Vector3.zero(), 0.95),
      radius: 0.6,
      halfExtents: vm.Vector3(0.6, 0.5, 0.6),
    );
    return _Fire(flame: flame, light: light);
  }

  Future<_Lamp> _buildLamp(vm.Vector3 at) async {
    final node = await _model('lantern', at: at, scale: 1.45);
    final glow = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.9, 0.85, 0.6, 1)
      ..emissiveFactor = vm.Vector4(1, 0.8, 0.45, 1)
      ..emissiveStrength = 0;
    final bulb = Node(
      name: 'bulb',
      mesh: Mesh(SphereGeometry(radius: 0.09), glow),
    )..position = at + vm.Vector3(0, 1.97, 0);
    final light = PointLight(
      color: vm.Vector3(1, 0.8, 0.5),
      intensity: 0,
      range: 9,
    );
    bulb.addComponent(PointLightComponent(light));
    scene.root.add(bulb);
    _things[IslandThing.lamp] = _Thing(
      node: node,
      focus: at + vm.Vector3(0, 1.4, 0),
      approach: at + _toward(at, vm.Vector3.zero(), 0.7),
      radius: 0.3,
      halfExtents: vm.Vector3(0.4, 1.2, 0.4),
    );
    return _Lamp(glow: glow, light: light);
  }

  Future<void> _buildThings() async {
    final treeAt = vm.Vector3(3.0, 0, 2.3);
    _things[IslandThing.tree] = _Thing(
      node: await _model('tree_oak', at: treeAt, scale: 3.0, yaw: 0.6),
      focus: treeAt + vm.Vector3(0, 1.6, 0),
      approach: treeAt + _toward(treeAt, vm.Vector3.zero(), 1.0),
      radius: 0.55,
      halfExtents: vm.Vector3(1.1, 1.9, 1.1),
    );

    final chestAt = vm.Vector3(-3.7, 0, -0.4);
    _chest = await _model(
      'chest',
      at: chestAt,
      scale: 2.6,
      yaw: _yawFacing(vm.Vector3.zero() - chestAt),
    );
    _things[IslandThing.chest] = _Thing(
      node: _chest,
      focus: chestAt + vm.Vector3(0, 0.3, 0),
      approach: chestAt + _toward(chestAt, vm.Vector3.zero(), 1.0),
      radius: 0.55,
      halfExtents: vm.Vector3(0.6, 0.5, 0.6),
    );

    final bedAt = vm.Vector3(-2.2, 0, -2.6);
    _flowerBed = Node(name: 'flower-bed')..position = bedAt;
    scene.root.add(_flowerBed);
    _flowerBed.add(
      Node(
        name: 'soil',
        mesh: Mesh(
          CylinderGeometry(bottomRadius: 0.95, topRadius: 0.9, height: 0.1),
          _matte(0.42, 0.27, 0.16),
        ),
      )..position = vm.Vector3(0, 0.03, 0),
    );
    const kinds = ['flower_redA', 'flower_yellowA', 'flower_purpleA'];
    for (var i = 0; i < 7; i++) {
      final angle = i * 2 * math.pi / 7;
      final r = i.isEven ? 0.55 : 0.35;
      _flowers.add(
        await _model(
          kinds[i % 3],
          at: vm.Vector3(math.cos(angle) * r, 0.07, math.sin(angle) * r),
          scale: 2.3,
          yaw: angle,
          parent: _flowerBed,
        ),
      );
    }
    _things[IslandThing.flowers] = _Thing(
      node: _flowerBed,
      focus: bedAt + vm.Vector3(0, 0.3, 0),
      approach: bedAt + _toward(bedAt, vm.Vector3.zero(), 1.35),
      radius: 0.95,
      halfExtents: vm.Vector3(1.0, 0.5, 1.0),
    );

    final rockAt = vm.Vector3(2.4, 0, -3.0);
    _things[IslandThing.rock] = _Thing(
      node: await _model('rock_largeA', at: rockAt, scale: 2.2, yaw: 0.4),
      focus: rockAt + vm.Vector3(0, 0.3, 0),
      approach: rockAt + _toward(rockAt, vm.Vector3.zero(), 1.45),
      radius: 1.1,
      halfExtents: vm.Vector3(1.1, 0.5, 1.2),
      top: 0.55,
    );

    final benchAt = vm.Vector3(-0.2, 0, 3.6);
    // The bench's long side runs along Z in the kit: turned to run along X,
    // facing the camera.
    _things[IslandThing.bench] = _Thing(
      node: await _model(
        'stall-bench',
        at: benchAt,
        scale: 2.0,
        yaw: math.pi / 2,
      ),
      focus: benchAt + vm.Vector3(0, 0.3, 0),
      approach: benchAt + vm.Vector3(0, 0, -0.85),
      radius: 0.95,
      halfExtents: vm.Vector3(1.0, 0.5, 0.4),
      top: 0.45,
    );

    final signAt = vm.Vector3(-1.9, 0, 0.5);
    _things[IslandThing.sign] = _Thing(
      node: await _model('sign', at: signAt, scale: 2.4, yaw: math.pi),
      focus: signAt + vm.Vector3(0, 0.7, 0),
      approach: signAt + vm.Vector3(0.15, 0, -0.8),
      radius: 0.35,
      halfExtents: vm.Vector3(0.5, 0.8, 0.5),
    );
  }

  Future<void> _buildDecor() async {
    // Scenery nobody acts on: two more trees, bushes, grass, mushrooms,
    // pebbles, a log by the fire and a canoe on the water.
    final decor = <(String, double, double, double, double)>[
      ('tree_pineRoundA', -4.3, 0.9, 2.4, 0.0),
      ('tree_default', 4.3, 0.8, 2.6, 1.0),
      ('tree_palmShort', 4.3, -2.3, 2.4, 2.2),
      ('plant_bush', -4.0, -1.9, 2.2, 0.0),
      ('plant_bush', 1.9, 4.1, 2.0, 1.2),
      ('plant_bush', -3.9, 3.6, 1.8, 0.4),
      ('grass', -0.9, -3.8, 2.2, 0.0),
      ('grass', 3.6, 1.0, 2.0, 1.1),
      ('grass', -1.2, 1.9, 2.0, 0.3),
      ('grass', 1.0, -0.6, 1.8, 2.0),
      ('mushroom_red', 3.5, 3.4, 2.4, 0.0),
      ('mushroom_red', -3.2, 1.4, 2.0, 1.0),
      ('rock_smallA', 1.4, -4.2, 2.4, 0.0),
      ('rock_smallC', -2.9, -3.9, 2.4, 1.0),
      ('log', 0.15, -3.2, 1.8, 1.4),
    ];
    for (final (name, x, z, scale, yaw) in decor) {
      await _model(name, at: vm.Vector3(x, 0, z), scale: scale, yaw: yaw);
    }
    await _model('canoe', at: vm.Vector3(5.9, -0.1, 1.6), scale: 2.2, yaw: 0.3);
  }

  Future<void> _buildCharacter() async {
    final model = await loadScene('$_models/character-male-a.glb');
    final scaler = Node(name: 'character-scale')
      ..scale = vm.Vector3.all(_characterScale);
    scaler.add(model);
    _actor = Node(name: 'character')..position = vm.Vector3(0, 0, 0.3);
    _actor.add(scaler);
    scene.root.add(_actor);
    _setYaw(_yawFacing(vm.Vector3(0, 0, -1)));

    // The kit's clips; the ones the scripts use are looked up by name and
    // blended by weight (one pose at a time, crossfaded).
    final animations = _findAnimations(model);
    onLog(
      'character clips: ${[for (final a in animations) '${a.name} ${a.endTime.toStringAsFixed(2)}s'].join(', ')}',
    );
    for (final animation in animations) {
      final clip = model.createAnimationClip(animation)
        ..weight = 0
        ..loop = true
        ..play();
      _clips[animation.name] = (clip: clip, length: animation.endTime);
    }
    _setPose('idle', instant: true);
  }

  static List<Animation> _findAnimations(Node node) {
    if (node.parsedAnimations.isNotEmpty) return node.parsedAnimations;
    for (final child in node.children) {
      final found = _findAnimations(child);
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  void _buildEffects() {
    final water = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.35, 0.6, 1, 1)
      ..roughnessFactor = 0.2
      ..metallicFactor = 0;
    for (var i = 0; i < 10; i++) {
      final drop = Node(
        name: 'droplet',
        mesh: Mesh(SphereGeometry(radius: 0.045, segments: 8, rings: 6), water),
      )..visible = false;
      scene.root.add(drop);
      _droplets.add(drop);
    }
    final gold = _matte(1, 0.78, 0.2, roughness: 0.3, metallic: 1);
    for (var i = 0; i < 6; i++) {
      final coin = Node(
        name: 'coin',
        mesh: Mesh(
          CylinderGeometry(
            bottomRadius: 0.08,
            topRadius: 0.08,
            height: 0.025,
            radialSegments: 16,
          ),
          gold,
        ),
      )..visible = false;
      scene.root.add(coin);
      _coins.add(coin);
    }
    final rainMaterial = UnlitMaterial()
      ..baseColorFactor = vm.Vector4(0.75, 0.82, 0.95, 1);
    _rain = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(0.012, 0.24, 0.012)),
      material: rainMaterial,
    );
    final random = math.Random(7);
    for (var i = 0; i < 420; i++) {
      final p = vm.Vector3(
        (random.nextDouble() * 2 - 1) * 7,
        random.nextDouble() * 8,
        (random.nextDouble() * 2 - 1) * 7,
      );
      _rainDrops.add(p);
      _rain.addInstance(vm.Matrix4.translation(p));
    }
    _rainNode = Node(name: 'rain')
      ..addComponent(InstancedMeshComponent(_rain))
      ..visible = false
      ..shadowCastingMode = ShadowCastingMode.off;
    scene.root.add(_rainNode);
  }

  void _buildCamera() {
    orbit = OrbitCameraController(
      target: _homeTarget,
      distance: _homeDistance,
      polar: _homePolar,
      minDistance: 2.5,
      maxDistance: 30,
      minPolar: 0.06,
      maxPolar: 1.48,
    );
    _cameraNode = Node(name: 'camera')
      ..addComponent(CameraComponent(activateOnMount: true))
      ..addComponent(orbit);
    scene.root.add(_cameraNode);
  }

  // Aimed above the island's middle, so the island sits low in the view and
  // the HUD, at the top, covers sky and water.
  static final _homeTarget = vm.Vector3(0, 1.5, 0.3);
  static const _homeDistance = 13.5;

  /// The home distance for the view's shape: farther on a tall, narrow view
  /// (a phone held upright), so the whole island still fits across.
  double _fitDistance = _homeDistance;

  /// Fits the island across a view of [size]. Called by the screen whenever
  /// its size is known or changes; a change under 5% is ignored, so the
  /// user's own zoom survives small resizes.
  void fitView(ui.Size size) {
    if (!_loaded || size.isEmpty) return;
    // The camera's vertical field of view is flutter_scene's default, 45°.
    const halfFov = 22.5 * math.pi / 180;
    final aspect = size.width / size.height;
    final needed = math.max(_homeDistance, 6.6 / (math.tan(halfFov) * aspect));
    if ((needed - _fitDistance).abs() / _fitDistance < 0.05) return;
    orbit.dollyBy(-math.log(needed / _fitDistance) / orbit.dollySpeed);
    _fitDistance = needed;
  }

  static const _homePolar = 0.58;

  // ------------------------------------------------------------- per frame

  final List<_Tween> _tweens = [];
  double _time = 0;
  bool _following = false;
  // Empty until the first pose is set, so setting 'idle' is never a no-op.
  String _pose = '';
  String? _fadingFrom;
  double _fade = 1;

  /// Advances the scripts, the pose crossfade, the fire, the rain and the
  /// camera follow by [dt] seconds. Called from `SceneView.onTick`.
  void tick(double dt) {
    if (!_loaded || _disposed) return;
    _time += dt;
    for (final tween in List.of(_tweens)) {
      tween.elapsed += dt;
      final t = (tween.elapsed / tween.duration).clamp(0.0, 1.0);
      tween.apply(tween.curve(t));
      if (t >= 1) {
        _tweens.remove(tween);
        tween.done.complete();
      }
    }
    _tickPose(dt);
    if (_fire.lit) {
      final flicker =
          1 + 0.08 * math.sin(_time * 17) + 0.05 * math.sin(_time * 31);
      _fire.flame.scale = vm.Vector3.all(_fire.size * flicker);
      _fire.light.intensity = _fire.size * (2.2 + 0.4 * math.sin(_time * 23));
    }
    if (_raining) {
      for (var i = 0; i < _rainDrops.length; i++) {
        final p = _rainDrops[i]..y -= dt * 9;
        if (p.y < 0) p.y += 8;
        _rain.setInstanceTransform(i, vm.Matrix4.translation(p));
      }
    }
    if (_following) {
      orbit.target = _actor.position + vm.Vector3(0, 0.7, 0);
    }
    frame.value++;
  }

  Future<void> _animate(
    double seconds,
    void Function(double t) apply, {
    double Function(double t) curve = _linear,
  }) {
    if (_disposed) return Future.value();
    final tween = _Tween(math.max(seconds, 1e-3), apply, curve);
    _tweens.add(tween);
    return tween.done.future;
  }

  static double _linear(double t) => t;
  static double _ease(double t) => Curves.easeInOut.transform(t);

  Future<void> _wait(double seconds) => _animate(seconds, (_) {});

  void _setPose(String name, {bool loop = true, bool instant = false}) {
    final next = _clips[name];
    if (next == null) {
      onLog('no clip named $name');
      return;
    }
    if (name == _pose && loop) return;
    next.clip
      ..loop = loop
      ..replay();
    if (instant) {
      for (final MapEntry(:key, :value) in _clips.entries) {
        value.clip.weight = key == name ? 1 : 0;
      }
      _fadingFrom = null;
      _fade = 1;
    } else {
      // The pose being left keeps its weight until the fade has finished.
      if (_fadingFrom case final from? when from != _pose) {
        _clips[from]?.clip.weight = 0;
      }
      _fadingFrom = _pose;
      _fade = 0;
    }
    _pose = name;
  }

  void _tickPose(double dt) {
    final from = _fadingFrom;
    if (from == null) return;
    _fade = math.min(1, _fade + dt / 0.18);
    _clips[_pose]?.clip.weight = _fade;
    if (from != _pose) _clips[from]?.clip.weight = 1 - _fade;
    if (_fade >= 1) {
      if (from != _pose) _clips[from]?.clip.weight = 0;
      _fadingFrom = null;
    }
  }

  /// Plays [name] once and returns to [then] (a looping pose).
  Future<void> _once(String name, {String then = 'idle', double speed = 1}) {
    final entry = _clips[name];
    if (entry == null) {
      onLog('no clip named $name');
      return Future.value();
    }
    entry.clip.playbackTimeScale = speed;
    _setPose(name, loop: false);
    return _wait(entry.length / speed * 0.95).then((_) {
      entry.clip.playbackTimeScale = 1;
      _setPose(then);
    });
  }

  // ------------------------------------------------------------ the stage

  Future<void> _queue = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<IslandOutcome> perform(IslandAction action) {
    if (!_loaded) {
      return Future.value(
        const IslandOutcome.declined('The island is still loading.'),
      );
    }
    return _enqueue(() => _play(action));
  }

  @override
  Future<void> shrug() {
    if (!_loaded) return Future.value();
    // The "?" shows at once, even while an earlier action is still playing;
    // the shrug itself waits its turn, and is skipped if the character is
    // sitting, lying or indoors by then.
    _say('?', 3.5);
    return _enqueue(() async {
      if (_posture != _Posture.standing || _inside) return;
      await _once('emote-no');
    });
  }

  void dispose() {
    _disposed = true;
    for (final tween in _tweens) {
      tween.done.complete();
    }
    _tweens.clear();
    bubble.dispose();
    frame.dispose();
  }

  // ------------------------------------------------------- state and moves

  _Posture _posture = _Posture.standing;
  bool _inside = false;
  bool _raining = false;
  _SkyKind _skyKind = _SkyKind.day;
  int _bubbleToken = 0;

  void _say(String? text, [double seconds = 2.6]) {
    final token = ++_bubbleToken;
    bubble.value = text;
    if (text == null || seconds <= 0) return;
    unawaited(
      _wait(seconds).then((_) {
        if (token == _bubbleToken && !_disposed) bubble.value = null;
      }),
    );
  }

  static vm.Vector3 _flat(vm.Vector3 v) => vm.Vector3(v.x, 0, v.z);

  /// A point [distance] from [from] toward [to], on the ground plane.
  static vm.Vector3 _toward(vm.Vector3 from, vm.Vector3 to, double distance) {
    final d = _flat(to - from);
    if (d.length < 1e-6) return vm.Vector3(0, 0, -distance);
    return d.normalized() * distance;
  }

  /// The yaw that turns the character to look along [direction]. The kit's
  /// characters face glTF +Z, which the importer's handedness flip makes -Z.
  static double _yawFacing(vm.Vector3 direction) =>
      math.atan2(-direction.x, -direction.z);

  double _yaw = 0;

  void _setYaw(double yaw) {
    _yaw = yaw;
    _actor.rotation = vm.Quaternion.axisAngle(_up, yaw);
  }

  Future<void> _turnTo(double yaw, {double seconds = 0.3}) {
    final from = _yaw;
    var delta = (yaw - from) % (2 * math.pi);
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta.abs() < 0.02) return Future.value();
    return _animate(
      seconds * (0.4 + delta.abs() / math.pi),
      (t) => _setYaw(from + delta * t),
      curve: _ease,
    );
  }

  Future<void> _face(vm.Vector3 point) {
    final d = _flat(point - _actor.position);
    if (d.length < 0.05) return Future.value();
    return _turnTo(_yawFacing(d));
  }

  vm.Vector3 get _cameraEye => _cameraNode.globalTransform.getTranslation();

  /// Stands the character up from whatever it was doing, and brings it out
  /// of the house.
  Future<void> _getUp() async {
    _say(null);
    if (_inside) await _comeOut();
    switch (_posture) {
      case _Posture.standing:
        return;
      case _Posture.lying || _Posture.sitting || _Posture.crouching:
        _posture = _Posture.standing;
        _setPose('idle');
        final p = _actor.position;
        if (p.y > 0.05) {
          // Off the bench or the rock: step down in front of it.
          final ground = p + _toward(p, vm.Vector3.zero(), 0.45)
            ..y = 0;
          await _move(ground, _Gait.walk);
        } else {
          await _wait(0.25);
        }
    }
  }

  Future<void> _walkTo(
    vm.Vector3 target, {
    _Gait gait = _Gait.walk,
    IslandThing? toward,
  }) async {
    await _getUp();
    for (final point in _route(_actor.position, target, toward)) {
      await _move(point, gait);
    }
    _setPose(gait == _Gait.sneak ? 'crouch' : 'idle');
    if (gait == _Gait.sneak) _posture = _Posture.crouching;
  }

  /// Straight to [target], or by the island's middle when a thing is in the
  /// way.
  List<vm.Vector3> _route(
    vm.Vector3 from,
    vm.Vector3 target,
    IslandThing? toward,
  ) {
    bool blocked(vm.Vector3 a, vm.Vector3 b) {
      for (final MapEntry(key: kind, value: thing) in _things.entries) {
        if (kind == toward) continue;
        if (_segmentDistance(_flat(a), _flat(b), _flat(thing.node.position)) <
            thing.radius + 0.25) {
          return true;
        }
      }
      return false;
    }

    final middle = vm.Vector3(0, 0, 0.3);
    if (!blocked(from, target) ||
        (from - middle).length < 0.5 ||
        (target - middle).length < 0.5) {
      return [target];
    }
    return [middle, target];
  }

  static double _segmentDistance(vm.Vector3 a, vm.Vector3 b, vm.Vector3 p) {
    final ab = b - a;
    final length2 = ab.length2;
    if (length2 < 1e-9) return (p - a).length;
    final t = ((p - a).dot(ab) / length2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).length;
  }

  Future<void> _move(vm.Vector3 to, _Gait gait) async {
    final from = _actor.position;
    final distance = (to - from).length;
    if (distance < 0.05) return;
    await _face(to);
    _setPose(gait.clip);
    await _animate(
      distance / gait.speed,
      (t) => _actor.position = from + (to - from) * t,
    );
  }

  _Thing _thing(IslandThing kind) => _things[kind]!;

  Future<void> _goTo(IslandThing kind, {_Gait gait = _Gait.walk}) async {
    final thing = _thing(kind);
    await _walkTo(thing.approach, gait: gait, toward: kind);
    await _face(thing.focus);
  }

  /// Rocks [node] about its own axes for a moment, then restores it.
  Future<void> _wobble(Node node, {double amount = 0.08, double seconds = 1}) {
    final base = node.rotation;
    return _animate(seconds, (t) {
      final angle = amount * math.sin(t * math.pi * 6) * (1 - t);
      node.rotation =
          base * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), angle);
    }).then((_) => node.rotation = base);
  }

  Future<void> _hop({double height = 0.55, double seconds = 0.5}) {
    final base = _actor.position;
    return _animate(seconds, (t) {
      _actor.position = base + vm.Vector3(0, height * 4 * t * (1 - t), 0);
    }).then((_) => _actor.position = base);
  }

  Future<void> _spin({double turns = 1, double seconds = 0.9}) {
    final from = _yaw;
    return _animate(
      seconds,
      (t) => _setYaw(from + turns * 2 * math.pi * t),
      curve: _ease,
    ).then((_) => _setYaw(from));
  }

  Future<void> _dance() async {
    _say('La la la!', 3);
    await _hop();
    await _spin(seconds: 0.7);
    await _once('emote-yes');
    await _hop(height: 0.35, seconds: 0.35);
    await _hop(height: 0.35, seconds: 0.35);
    await _spin(turns: -1, seconds: 0.7);
    await _once('interact-right', speed: 1.4);
  }

  Future<void> _wave() async {
    await _once('interact-right', speed: 1.2);
    await _once('interact-right', speed: 1.2);
  }

  // ------------------------------------------------------- house and props

  Future<bool> _setDoor(bool open) async {
    if (_house.doorOpen == open) return false;
    _house.doorOpen = open;
    final from = open ? 0.0 : -1.9;
    final to = open ? -1.9 : 0.0;
    await _animate(
      0.6,
      (t) => _house.hinge.rotation = vm.Quaternion.axisAngle(
        _up,
        from + (to - from) * t,
      ),
      curve: _ease,
    );
    return true;
  }

  Future<void> _goInside() async {
    await _goTo(IslandThing.house);
    if (!_house.doorOpen) {
      await _once('interact-right', speed: 1.3);
      await _setDoor(true);
    }
    final door = _house.hinge.globalTransform.getTranslation()
      ..x += 0.3
      ..y = 0;
    await _move(door, _Gait.walk);
    await _move(_house.inside, _Gait.walk);
    _actor.visible = false;
    _inside = true;
    _setPose('idle');
    await _setDoor(false);
  }

  Future<void> _comeOut() async {
    if (!_inside) return;
    await _setDoor(true);
    _actor.visible = true;
    _inside = false;
    final door = _house.hinge.globalTransform.getTranslation()
      ..x += 0.3
      ..y = 0;
    await _move(door, _Gait.walk);
    await _move(_thing(IslandThing.house).approach, _Gait.walk);
    _setPose('idle');
    await _setDoor(false);
  }

  void _setHouseLights(bool on) {
    _house.lightsOn = on;
    _house.windows
      ..emissiveFactor = on
          ? vm.Vector4(1, 0.75, 0.35, 1)
          : vm.Vector4(0, 0, 0, 1)
      ..emissiveStrength = on ? 3 : 0;
  }

  Future<void> _setLamp(bool on) {
    _lamp.on = on;
    final from = _lamp.glow.emissiveStrength;
    final to = on ? 9.0 : 0.0;
    return _animate(0.4, (t) {
      final v = from + (to - from) * t;
      _lamp.glow.emissiveStrength = v;
      // The bulb hangs two metres up: its light needs to be strong to
      // reach the ground.
      _lamp.light.intensity = v * 3.5;
    });
  }

  Future<void> _setFire(bool lit) {
    _fire.lit = lit;
    _fire.flame.visible = true;
    final from = _fire.size;
    final to = lit ? 1.0 : 0.0;
    return _animate(0.7, (t) {
      _fire.size = from + (to - from) * t;
      _fire.flame.scale = vm.Vector3.all(math.max(_fire.size, 0.001));
      _fire.light.intensity = _fire.size * 2.2;
    }).then((_) {
      if (!lit) _fire.flame.visible = false;
    });
  }

  AnimationClip? _chestPlaying;

  /// Plays the chest's own `open` or `close` clip. The previous one is
  /// removed first: a finished clip holds its last pose and would blend in.
  Future<void> _chestClip(String name) async {
    final model = _chest.children.first;
    final animation = _findAnimations(
      model,
    ).where((a) => a.name == name).firstOrNull;
    if (animation == null) {
      onLog('the chest has no $name clip');
      return;
    }
    if (_chestPlaying case final previous?) {
      model.removeAnimationClip(previous);
    }
    final clip = model.createAnimationClip(animation)..loop = false;
    _chestPlaying = clip;
    clip.play();
    await _wait(animation.endTime);
  }

  Future<void> _splash(vm.Vector3 over) {
    final random = math.Random();
    final starts = [
      for (final _ in _droplets)
        over +
            vm.Vector3(
              (random.nextDouble() - 0.5) * 1.2,
              1.3 + random.nextDouble() * 0.4,
              (random.nextDouble() - 0.5) * 1.2,
            ),
    ];
    for (final drop in _droplets) {
      drop.visible = true;
    }
    return _animate(0.8, (t) {
      for (var i = 0; i < _droplets.length; i++) {
        _droplets[i].position = starts[i] - vm.Vector3(0, 1.3 * t * t, 0);
      }
    }).then((_) {
      for (final drop in _droplets) {
        drop.visible = false;
      }
    });
  }

  Future<void> _coinsFly(vm.Vector3 from, vm.Vector3 to, int count) {
    final used = _coins.take(count).toList();
    for (final coin in used) {
      coin.visible = true;
    }
    return _animate(0.9, (t) {
      for (var i = 0; i < used.length; i++) {
        final s = (t * 1.3 - i * 0.06).clamp(0.0, 1.0);
        used[i].position =
            from + (to - from) * s + vm.Vector3(0, 1.2 * 4 * s * (1 - s), 0);
      }
    }).then((_) {
      for (final coin in used) {
        coin.visible = false;
      }
    });
  }

  Future<void> _plantSprout() async {
    final angle = _sprouts.length * 2.4;
    final at = vm.Vector3(math.cos(angle) * 0.2, 0.07, math.sin(angle) * 0.2);
    Node sprout;
    if (_sprouts.length >= 4) {
      sprout = _sprouts.removeAt(0)..position = at;
    } else {
      sprout = await _model(
        'crops_leafsStageA',
        at: at,
        scale: 0.01,
        parent: _flowerBed,
      );
    }
    _sprouts.add(sprout);
    await _animate(
      1.2,
      (t) => sprout.scale = vm.Vector3.all(0.01 + 1.9 * t),
      curve: Curves.elasticOut.transform,
    );
  }

  // ------------------------------------------------------------- the sky

  /// [wetness] 0 is a clear sky, 1 full rain: grayer, dimmer, no sun disk.
  void _applySky(_SkyLook look, {required double wetness}) {
    final gray = vm.Vector3(0.42, 0.45, 0.5);
    vm.Vector3 wet(vm.Vector3 c) {
      final overcast = gray * (0.25 + 0.75 * c.length / 1.2);
      return c + (overcast - c) * (0.6 * wetness);
    }

    _sky
      ..zenithColor = wet(look.zenith)
      ..horizonColor = wet(look.horizon)
      ..groundColor = look.ground
      ..sunDirection = look.sunDirection
      ..sunColor = look.sunColor * (1 - 0.85 * wetness);
    _sun
      ..direction = -look.sunDirection
      ..color = look.lightColor
      ..intensity = look.lightIntensity * (1 - 0.55 * wetness);
    scene.environmentIntensity = look.environment * (1 - 0.3 * wetness);
  }

  Future<bool> _changeSky({_SkyKind? kind, bool? raining}) async {
    final nextKind = kind ?? _skyKind;
    final nextRain = raining ?? _raining;
    if (nextKind == _skyKind && nextRain == _raining) return false;
    final from = _skies[_skyKind]!;
    final to = _skies[nextKind]!;
    final wetFrom = _raining ? 1.0 : 0.0;
    final wetTo = nextRain ? 1.0 : 0.0;
    _skyKind = nextKind;
    _raining = nextRain;
    if (nextRain) _rainNode.visible = true;
    await _animate(1.6, (t) {
      _applySky(
        _SkyLook.lerp(from, to, t),
        wetness: wetFrom + (wetTo - wetFrom) * t,
      );
    }, curve: _ease);
    if (!nextRain) _rainNode.visible = false;
    return true;
  }

  // ------------------------------------------------------------- camera

  vm.Vector3 _orbitOffset() => _cameraEye - orbit.target;

  double get _polar {
    final offset = _orbitOffset();
    return math.asin((offset.y / offset.length).clamp(-1.0, 1.0));
  }

  double get _azimuth {
    final offset = _orbitOffset();
    return math.atan2(-offset.x, -offset.z);
  }

  void _resetCamera() {
    _following = false;
    var turn = (-_azimuth) % (2 * math.pi);
    if (turn > math.pi) turn -= 2 * math.pi;
    orbit
      ..frame(
        vm.Aabb3.centerAndHalfExtents(
          _homeTarget,
          vm.Vector3.all(_fitDistance / (2 * 1.5 * math.sqrt(3))),
        ),
      )
      ..orbitBy(turn, _homePolar - _polar);
  }

  // ------------------------------------------------------------- scripts

  Future<IslandOutcome> _play(IslandAction action) async {
    final kind = action.thing;
    switch (action.verb) {
      // ---- any thing
      case IslandVerb.walkTo:
        await _goTo(kind!);
      case IslandVerb.runTo:
        await _goTo(kind!, gait: _Gait.run);
      case IslandVerb.sneakTo:
        await _goTo(kind!, gait: _Gait.sneak);
      case IslandVerb.lookAt:
        await _getUp();
        await _face(_thing(kind!).focus);
        await _once('emote-yes');
      case IslandVerb.pointAt:
        await _getUp();
        await _face(_thing(kind!).focus);
        _say('There!', 1.8);
        await _once('interact-right', speed: 0.8);
      case IslandVerb.touch:
        await _goTo(kind!);
        await _once('interact-right');
      case IslandVerb.kick:
        await _goTo(kind!);
        await _once(
          _clips.containsKey('attack-kick-right')
              ? 'attack-kick-right'
              : 'interact-right',
        );
        await _wobble(_thing(kind).node, amount: 0.05, seconds: 0.6);
        if (kind == IslandThing.rock) _say('Ouch!', 1.8);
      case IslandVerb.hideBehind:
        final thing = _thing(kind!);
        final away = _toward(_cameraEye, thing.node.position, 1);
        final spot = _flat(thing.node.position) + away * (thing.radius + 0.55);
        await _walkTo(spot, gait: _Gait.run, toward: kind);
        await _face(_cameraEye);
        _setPose('crouch');
        _posture = _Posture.crouching;
        _say('Shh...', 2);
      case IslandVerb.walkAround:
        final thing = _thing(kind!);
        final center = _flat(thing.node.position);
        final r = thing.radius + 0.6;
        final start = math.atan2(
          _actor.position.z - center.z,
          _actor.position.x - center.x,
        );
        await _getUp();
        for (var i = 0; i <= 8; i++) {
          final a = start + i * 2 * math.pi / 8;
          await _move(
            center + vm.Vector3(math.cos(a) * r, 0, math.sin(a) * r),
            _Gait.walk,
          );
        }
        _setPose('idle');
      case IslandVerb.waveAt:
        await _getUp();
        await _face(_thing(kind!).focus);
        _say('Hi, ${kind.name}!', 2);
        await _wave();
      case IslandVerb.danceBy:
        await _goTo(kind!);
        await _dance();
      case IslandVerb.cameraOn:
        final thing = _thing(kind!);
        _following = false;
        orbit.frame(
          vm.Aabb3.centerAndHalfExtents(thing.focus, thing.halfExtents),
          margin: 1.6,
        );
        await _wait(0.8);

      // ---- one thing each
      case IslandVerb.climb when kind == IslandThing.tree:
        await _goTo(IslandThing.tree);
        final base = _actor.position;
        final trunk = _flat(_thing(IslandThing.tree).node.position);
        final perch = base + (trunk - _flat(base)) * 0.55
          ..y = 1.55;
        _setPose('jump');
        await _animate(0.9, (t) {
          _actor.position = base + (perch - base) * t;
        }, curve: _ease);
        _setPose('idle');
        _say('What a view!', 2);
        await _wait(1.8);
        _setPose('jump');
        await _animate(0.6, (t) {
          _actor.position = perch + (base - perch) * t;
        }, curve: _ease);
        _setPose('idle');
      case IslandVerb.climb:
        // The rock.
        await _goTo(IslandThing.rock);
        final rock = _thing(IslandThing.rock);
        final top =
            _flat(rock.node.position) +
                  _toward(rock.node.position, _actor.position, 0.25)
              ..y = rock.top;
        final base = _actor.position;
        _setPose('jump');
        await _animate(0.6, (t) {
          _actor.position =
              base + (top - base) * t + vm.Vector3(0, 0.5 * 4 * t * (1 - t), 0);
        });
        _setPose('idle');
        _posture = _Posture.sitting; // so the next move steps down first
        await _face(_cameraEye);
        await _once('emote-yes');
        _setPose('idle');
      case IslandVerb.shake:
        await _goTo(IslandThing.tree);
        await _once('interact-right', speed: 1.4);
        await _wobble(
          _thing(IslandThing.tree).node,
          amount: 0.06,
          seconds: 1.4,
        );
      case IslandVerb.hug:
        await _goTo(IslandThing.tree);
        _say('<3', 2);
        await _once('interact-right', speed: 0.7);
      case IslandVerb.sitUnder:
        await _goTo(IslandThing.tree);
        await _face(_cameraEye);
        _setPose('sit');
        _posture = _Posture.sitting;
      case IslandVerb.open when kind == IslandThing.house:
        await _goTo(IslandThing.house);
        if (_house.doorOpen) {
          return const IslandOutcome.declined('The door is already open.');
        }
        await _once('interact-right', speed: 1.3);
        await _setDoor(true);
      case IslandVerb.close when kind == IslandThing.house:
        if (!_house.doorOpen) {
          return const IslandOutcome.declined('The door is already closed.');
        }
        await _goTo(IslandThing.house);
        await _once('interact-right', speed: 1.3);
        await _setDoor(false);
      case IslandVerb.knock:
        await _goTo(IslandThing.house);
        _say('Knock knock!', 2);
        await _once('interact-right', speed: 1.6);
        await _once('interact-right', speed: 1.6);
        await _wait(0.4);
        return const IslandOutcome.done('Nobody is home.');
      case IslandVerb.goInside:
        if (_inside) {
          return const IslandOutcome.declined('Already inside.');
        }
        await _goInside();
      case IslandVerb.comeOut:
        if (!_inside) {
          return const IslandOutcome.declined('Not inside the house.');
        }
        await _comeOut();
      case IslandVerb.lightsOn:
        if (_house.lightsOn) {
          return const IslandOutcome.declined('The house lights are on.');
        }
        _setHouseLights(true);
        await _wait(0.4);
      case IslandVerb.lightsOff:
        if (!_house.lightsOn) {
          return const IslandOutcome.declined('The house lights are off.');
        }
        _setHouseLights(false);
        await _wait(0.4);
      case IslandVerb.turnOn:
        if (_lamp.on) {
          return const IslandOutcome.declined('The lamp is already on.');
        }
        await _goTo(IslandThing.lamp);
        await _once('interact-right');
        await _setLamp(true);
      case IslandVerb.turnOff:
        if (!_lamp.on) {
          return const IslandOutcome.declined('The lamp is already off.');
        }
        await _goTo(IslandThing.lamp);
        await _once('interact-right');
        await _setLamp(false);
      case IslandVerb.drawWater:
        await _goTo(IslandThing.well);
        _setPose('crouch');
        final rest = _well.rest;
        await _animate(0.8, (t) {
          _well.bucket.position = rest - vm.Vector3(0, 0.75 * t, 0);
        }, curve: _ease);
        await _animate(1.0, (t) {
          _well.bucket.position = rest - vm.Vector3(0, 0.75 * (1 - t), 0);
        }, curve: _ease);
        _setPose('idle');
        _say('Fresh water!', 2);
      case IslandVerb.throwCoin:
        await _goTo(IslandThing.well);
        await _once('interact-right');
        await _coinsFly(
          _actor.position + vm.Vector3(0, 0.9, 0),
          _thing(IslandThing.well).focus,
          1,
        );
        _say('Wish made!', 2);
      case IslandVerb.peekInto:
        await _goTo(IslandThing.well);
        _setPose('crouch');
        _posture = _Posture.crouching;
        _say('So deep...', 2.2);
        await _wait(1.6);
      case IslandVerb.open:
        // The chest.
        await _goTo(IslandThing.chest);
        if (_chestOpen) {
          return const IslandOutcome.declined('The chest is already open.');
        }
        await _once('interact-right');
        _chestOpen = true;
        await _chestClip('open');
      case IslandVerb.close:
        if (!_chestOpen) {
          return const IslandOutcome.declined('The chest is already closed.');
        }
        await _goTo(IslandThing.chest);
        await _once('interact-right');
        _chestOpen = false;
        await _chestClip('close');
      case IslandVerb.takeTreasure:
        await _goTo(IslandThing.chest);
        if (!_chestOpen) {
          await _once('interact-right');
          _chestOpen = true;
          await _chestClip('open');
        }
        await _once('pick-up');
        await _coinsFly(
          _thing(IslandThing.chest).focus,
          _actor.position + vm.Vector3(0, 0.8, 0),
          5,
        );
        _say('+5 gold!', 2);
      case IslandVerb.water:
        await _goTo(IslandThing.flowers);
        await _once('interact-right', speed: 0.8);
        await _splash(_flowerBed.position);
        await _wobble(_flowerBed, amount: 0.03, seconds: 0.6);
      case IslandVerb.pick:
        await _goTo(IslandThing.flowers);
        await _once('pick-up');
        final flower = _flowers.where((f) => f.visible).firstOrNull;
        if (flower == null) {
          return const IslandOutcome.declined('No flowers left to pick.');
        }
        final scale = flower.scale.x;
        await _animate(
          0.4,
          (t) => flower.scale = vm.Vector3.all(scale * (1 - t) + 1e-3),
        );
        flower.visible = false;
        _say('For you!', 2);
      case IslandVerb.smell:
        await _goTo(IslandThing.flowers);
        _setPose('crouch');
        _say('Mmm...', 2);
        await _wait(1.6);
        _setPose('idle');
      case IslandVerb.plant:
        await _goTo(IslandThing.flowers);
        await _once('pick-up');
        await _plantSprout();
        // A picked flower grows back too.
        for (final flower in _flowers.where((f) => !f.visible)) {
          flower
            ..visible = true
            ..scale = vm.Vector3.all(2.3);
        }
      case IslandVerb.sitOn:
        final thing = _thing(kind!);
        await _goTo(kind);
        final seat =
            _flat(thing.node.position) +
                  (kind == IslandThing.rock
                      ? _toward(thing.node.position, _actor.position, 0.3)
                      : vm.Vector3(0, 0, -0.05))
              ..y = thing.top;
        await _face(_cameraEye);
        final from = _actor.position;
        await _animate(0.4, (t) => _actor.position = from + (seat - from) * t);
        _setPose('sit');
        _posture = _Posture.sitting;
      case IslandVerb.push:
        await _goTo(IslandThing.rock);
        await _once('interact-right', speed: 0.6);
        await _wobble(_thing(IslandThing.rock).node, amount: 0.02);
        return const IslandOutcome.done('Too heavy to move.');
      case IslandVerb.lieOn:
        final bench = _thing(IslandThing.bench);
        await _goTo(IslandThing.bench);
        final from = _actor.position;
        final seat = _flat(bench.node.position)..y = bench.top;
        await _animate(0.4, (t) => _actor.position = from + (seat - from) * t);
        await _turnTo(_yawFacing(vm.Vector3(1, 0, 0)));
        _setPose('die', loop: false);
        _posture = _Posture.lying;
        _say('Zzz', 0);
      case IslandVerb.light:
        if (_fire.lit) {
          return const IslandOutcome.declined('The fire is already burning.');
        }
        await _goTo(IslandThing.campfire);
        await _once('interact-right');
        await _setFire(true);
      case IslandVerb.putOut:
        if (!_fire.lit) {
          return const IslandOutcome.declined('The fire is already out.');
        }
        await _goTo(IslandThing.campfire);
        await _once('interact-right');
        await _setFire(false);
        _say('Pssst.', 1.6);
      case IslandVerb.warmUp:
        await _goTo(IslandThing.campfire);
        if (!_fire.lit) {
          return const IslandOutcome.declined(
            'The fire is out: light it first.',
          );
        }
        _setPose('crouch');
        _say('So warm...', 2.2);
        await _wait(2);
        _setPose('idle');
      case IslandVerb.roast:
        await _goTo(IslandThing.campfire);
        if (!_fire.lit) {
          return const IslandOutcome.declined(
            'The fire is out: light it first.',
          );
        }
        _setPose('crouch');
        await _wait(1.4);
        _setPose('idle');
        _say('Mmm, marshmallows!', 2.2);
        await _once('emote-yes');
      case IslandVerb.read:
        await _goTo(IslandThing.sign);
        _say('"Tiny Island. Population: 1."', 3.2);
        await _wait(2.4);
        return const IslandOutcome.done(
          'The sign says: "Tiny Island. Population: 1."',
        );

      // ---- the character
      case IslandVerb.jump:
        await _getUp();
        _setPose('jump', loop: false);
        await _hop(height: 0.8, seconds: 0.6);
        _setPose('idle');
      case IslandVerb.dance:
        await _getUp();
        await _face(_cameraEye);
        await _dance();
      case IslandVerb.wave:
        await _getUp();
        await _face(_cameraEye);
        _say('Hello!', 2);
        await _wave();
      case IslandVerb.sleep:
        if (_posture == _Posture.lying) {
          return const IslandOutcome.declined('Already asleep.');
        }
        await _getUp();
        _setPose('die', loop: false);
        _posture = _Posture.lying;
        _say('Zzz', 0);
      case IslandVerb.wakeUp:
        if (_posture != _Posture.lying) {
          return const IslandOutcome.declined('Already awake.');
        }
        await _getUp();
        _say('Good morning!', 2);
        await _once('emote-yes');
      case IslandVerb.sitDown:
        if (_posture == _Posture.sitting) {
          return const IslandOutcome.declined('Already sitting.');
        }
        await _getUp();
        _setPose('sit');
        _posture = _Posture.sitting;
      case IslandVerb.standUp:
        if (_posture == _Posture.standing && !_inside) {
          return const IslandOutcome.declined('Already standing.');
        }
        await _getUp();
      case IslandVerb.crouch:
        await _getUp();
        _setPose('crouch');
        _posture = _Posture.crouching;
      case IslandVerb.spin:
        await _getUp();
        await _spin();
      case IslandVerb.nod:
        await _getUp();
        await _face(_cameraEye);
        await _once('emote-yes');
      case IslandVerb.shakeHead:
        await _getUp();
        await _face(_cameraEye);
        await _once('emote-no');
      case IslandVerb.cheer:
        await _getUp();
        await _face(_cameraEye);
        _say('Hooray!', 2);
        await _hop();
        await _hop();
        await _once('emote-yes');
      case IslandVerb.turnLeft:
        await _getUp();
        await _turnTo(_yaw + math.pi / 2);
      case IslandVerb.turnRight:
        await _getUp();
        await _turnTo(_yaw - math.pi / 2);
      case IslandVerb.turnAround:
        await _getUp();
        await _turnTo(_yaw + math.pi);
      case IslandVerb.walkForward:
        await _getUp();
        final forward = vm.Vector3(-math.sin(_yaw), 0, -math.cos(_yaw));
        final target = _actor.position + forward * 1.6;
        if (_flat(target).length > 4.3) {
          return const IslandOutcome.declined(
            'That is the edge of the island.',
          );
        }
        await _walkTo(target);
      case IslandVerb.comeBack:
        await _walkTo(vm.Vector3(0, 0, 0.3));
        await _face(_cameraEye);
      case IslandVerb.stop:
        await _getUp();
        _setPose('idle');
      case IslandVerb.lookAtMe:
        await _getUp();
        await _face(_cameraEye);
        _say('Hi!', 1.5);

      // ---- the world
      case IslandVerb.makeDay:
        if (!await _changeSky(kind: _SkyKind.day)) {
          return const IslandOutcome.declined('It is already day.');
        }
      case IslandVerb.makeNight:
        if (!await _changeSky(kind: _SkyKind.night)) {
          return const IslandOutcome.declined('It is already night.');
        }
      case IslandVerb.makeSunset:
        if (!await _changeSky(kind: _SkyKind.sunset)) {
          return const IslandOutcome.declined('The sun is already setting.');
        }
      case IslandVerb.startRain:
        if (!await _changeSky(raining: true)) {
          return const IslandOutcome.declined('It is already raining.');
        }
      case IslandVerb.stopRain:
        if (!await _changeSky(raining: false)) {
          return const IslandOutcome.declined('It is not raining.');
        }

      // ---- the camera
      case IslandVerb.zoomIn:
        orbit.dollyBy(4);
        await _wait(0.6);
      case IslandVerb.zoomOut:
        orbit.dollyBy(-4);
        await _wait(0.6);
      case IslandVerb.orbitLeft:
        orbit.orbitBy(-0.9, 0);
        await _wait(0.6);
      case IslandVerb.orbitRight:
        orbit.orbitBy(0.9, 0);
        await _wait(0.6);
      case IslandVerb.topView:
        _following = false;
        orbit.orbitBy(0, 1.45 - _polar);
        await _wait(0.8);
      case IslandVerb.resetCamera:
        _resetCamera();
        await _wait(0.8);
      case IslandVerb.followMe:
        if (_following) {
          return const IslandOutcome.declined('The camera already follows.');
        }
        _following = true;
        orbit.dollyBy(3);
        await _wait(0.6);
    }
    return const IslandOutcome.done();
  }

  bool _chestOpen = false;
}

// ------------------------------------------------------------------ helpers

enum _Posture { standing, sitting, lying, crouching }

enum _Gait {
  walk('walk', 1.7),
  run('sprint', 3.8),
  sneak('crouch', 0.9);

  const _Gait(this.clip, this.speed);
  final String clip;
  final double speed;
}

final class _Tween {
  _Tween(this.duration, this.apply, this.curve);

  final double duration;
  final void Function(double t) apply;
  final double Function(double t) curve;
  final Completer<void> done = Completer<void>();
  double elapsed = 0;
}

/// A thing on the island: its node, where to look at it, where to stand to
/// use it, how much room it takes, and how high its top is.
final class _Thing {
  _Thing({
    required this.node,
    required this.focus,
    required this.approach,
    required this.radius,
    required this.halfExtents,
    this.top = 0,
  });

  final Node node;
  final vm.Vector3 focus;
  final vm.Vector3 approach;
  final double radius;
  final vm.Vector3 halfExtents;
  final double top;
}

final class _House {
  _House({required this.hinge, required this.windows, required this.inside});

  final Node hinge;
  final PhysicallyBasedMaterial windows;
  final vm.Vector3 inside;
  bool doorOpen = false;
  bool lightsOn = false;
}

final class _Lamp {
  _Lamp({required this.glow, required this.light});

  final PhysicallyBasedMaterial glow;
  final PointLight light;
  bool on = false;
}

final class _Fire {
  _Fire({required this.flame, required this.light});

  final Node flame;
  final PointLight light;
  bool lit = false;
  double size = 0;
}

final class _Well {
  _Well({required this.bucket, required this.rest});

  final Node bucket;
  final vm.Vector3 rest;
}

enum _SkyKind { day, sunset, night }

final class _SkyLook {
  const _SkyLook({
    required this.zenith,
    required this.horizon,
    required this.ground,
    required this.sunDirection,
    required this.sunColor,
    required this.lightColor,
    required this.lightIntensity,
    required this.environment,
  });

  final vm.Vector3 zenith;
  final vm.Vector3 horizon;
  final vm.Vector3 ground;
  final vm.Vector3 sunDirection;
  final vm.Vector3 sunColor;
  final vm.Vector3 lightColor;
  final double lightIntensity;
  final double environment;

  static _SkyLook lerp(_SkyLook a, _SkyLook b, double t) {
    vm.Vector3 mix(vm.Vector3 x, vm.Vector3 y) => x + (y - x) * t;
    double mixd(double x, double y) => x + (y - x) * t;
    return _SkyLook(
      zenith: mix(a.zenith, b.zenith),
      horizon: mix(a.horizon, b.horizon),
      ground: mix(a.ground, b.ground),
      sunDirection: mix(a.sunDirection, b.sunDirection).normalized(),
      sunColor: mix(a.sunColor, b.sunColor),
      lightColor: mix(a.lightColor, b.lightColor),
      lightIntensity: mixd(a.lightIntensity, b.lightIntensity),
      environment: mixd(a.environment, b.environment),
    );
  }
}

final _skies = <_SkyKind, _SkyLook>{
  _SkyKind.day: _SkyLook(
    zenith: vm.Vector3(0.12, 0.36, 0.85),
    horizon: vm.Vector3(0.62, 0.8, 0.96),
    ground: vm.Vector3(0.2, 0.3, 0.35),
    sunDirection: vm.Vector3(0.35, 0.8, -0.45).normalized(),
    sunColor: vm.Vector3(3, 2.8, 2.4),
    lightColor: vm.Vector3(1, 0.97, 0.9),
    lightIntensity: 3,
    environment: 1,
  ),
  _SkyKind.sunset: _SkyLook(
    zenith: vm.Vector3(0.22, 0.2, 0.45),
    horizon: vm.Vector3(1, 0.52, 0.25),
    ground: vm.Vector3(0.2, 0.15, 0.15),
    sunDirection: vm.Vector3(0.75, 0.12, -0.65).normalized(),
    sunColor: vm.Vector3(3, 1.5, 0.6),
    lightColor: vm.Vector3(1, 0.62, 0.38),
    lightIntensity: 2,
    environment: 0.55,
  ),
  _SkyKind.night: _SkyLook(
    zenith: vm.Vector3(0.01, 0.015, 0.05),
    horizon: vm.Vector3(0.04, 0.07, 0.16),
    ground: vm.Vector3(0.02, 0.03, 0.05),
    sunDirection: vm.Vector3(-0.35, 0.75, -0.55).normalized(),
    sunColor: vm.Vector3(0.9, 0.95, 1.1),
    lightColor: vm.Vector3(0.55, 0.65, 1),
    lightIntensity: 0.35,
    environment: 0.12,
  ),
};
