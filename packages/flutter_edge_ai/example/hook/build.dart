import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

/// Converts the Tiny Island models (`assets/island/**/*.glb`) into
/// flutter_scene's `.fsceneb` at build time, into `flutter_scene_generated/`,
/// where `loadScene('assets/island/models/<name>.glb')` finds them.
///
/// Written by `dart run flutter_scene:init`, then narrowed to
/// `assets/island/`: the rest of `assets/` holds models, photos and clips for
/// the other screens, which the scene pipeline must not walk. There are no
/// `.fmat` materials, so the generated `buildMaterials` call is left out.
void main(List<String> args) async {
  await build(args, (input, output) async {
    buildScenes(
      buildInput: input,
      buildOutput: output,
      discoveryRoot: 'assets/island/',
    );
  });
}
