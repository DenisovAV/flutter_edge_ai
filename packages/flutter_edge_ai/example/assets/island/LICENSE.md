# Tiny Island models

Every model in `models/` is by **Kenney** (www.kenney.nl), released under
**Creative Commons Zero (CC0 1.0)**:
http://creativecommons.org/publicdomain/zero/1.0/ — free for personal,
educational and commercial use; crediting Kenney is appreciated, not required.

| File | Kit | Source |
| --- | --- | --- |
| `character-male-a.glb` | Mini Characters 1.0 | https://kenney.nl/assets/mini-characters |
| `chest.glb`, `bucket.glb` | Survival Kit | https://kenney.nl/assets/survival-kit |
| `lantern.glb`, `stall-bench.glb` | Fantasy Town Kit 2.0 | https://kenney.nl/assets/fantasy-town-kit |
| `tree_oak.glb`, `tree_default.glb`, `tree_pineRoundA.glb`, `tree_palmShort.glb`, `rock_largeA.glb`, `rock_smallA.glb`, `rock_smallC.glb`, `flower_redA.glb`, `flower_yellowA.glb`, `flower_purpleA.glb`, `grass.glb`, `plant_bush.glb`, `mushroom_red.glb`, `campfire_stones.glb`, `sign.glb`, `crops_leafsStageA.glb`, `canoe.glb`, `log.glb` | Nature Kit 2.1 | https://kenney.nl/assets/nature-kit |

The Mini Characters, Survival Kit and Fantasy Town Kit models reference their
kit's `Textures/colormap.png` by URI; here that PNG is embedded in each `.glb`
(a buffer view instead of the URI), unchanged, so every file is self-contained.
The Nature Kit files list their mesh node both as the scene's root and as the
child of an unused `tmpParent` node, which flutter_scene's importer refuses
("Child already has a parent"); here the scene's root is `tmpParent` instead,
which places the mesh exactly where it was. Geometry, materials and textures
are unchanged in every file.

The house, the well, the island, the water, the flames, the rain and the
coins are built at run time from flutter_scene's primitives
(`lib/tiny_island/island_world.dart`).
