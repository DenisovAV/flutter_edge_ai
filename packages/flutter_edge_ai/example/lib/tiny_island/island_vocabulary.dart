/// The things on Tiny Island the character can act on.
enum IslandThing {
  tree,
  house,
  lamp,
  well,
  chest,
  flowers,
  rock,
  bench,
  campfire,
  sign,
}

/// What an action does. The stage maps every verb (with its [IslandThing],
/// when it has one) to a short scripted animation; the Decider never sees
/// these, only the action ids, descriptions and example phrasings.
enum IslandVerb {
  // Any thing.
  walkTo('walk_to'),
  runTo('run_to'),
  sneakTo('sneak_to'),
  lookAt('look_at'),
  pointAt('point_at'),
  touch('touch'),
  kick('kick'),
  hideBehind('hide_behind'),
  walkAround('walk_around'),
  waveAt('wave_at'),
  danceBy('dance_by'),
  cameraOn('camera_on'),

  // One thing each.
  climb('climb'),
  shake('shake'),
  hug('hug'),
  sitUnder('sit_under'),
  open('open'),
  close('close'),
  knock('knock'),
  goInside('go_inside'),
  comeOut('come_out'),
  lightsOn('lights_on'),
  lightsOff('lights_off'),
  turnOn('turn_on'),
  turnOff('turn_off'),
  drawWater('draw_water'),
  throwCoin('throw_coin'),
  peekInto('peek_into'),
  takeTreasure('take_treasure'),
  water('water'),
  pick('pick'),
  smell('smell'),
  plant('plant'),
  sitOn('sit_on'),
  push('push'),
  lieOn('lie_on'),
  light('light'),
  putOut('put_out'),
  warmUp('warm_up'),
  roast('roast'),
  read('read'),

  // The character, anywhere.
  jump('jump'),
  dance('dance'),
  wave('wave'),
  sleep('sleep'),
  wakeUp('wake_up'),
  sitDown('sit_down'),
  standUp('stand_up'),
  crouch('crouch'),
  spin('spin'),
  nod('nod'),
  shakeHead('shake_head'),
  cheer('cheer'),
  turnLeft('turn_left'),
  turnRight('turn_right'),
  turnAround('turn_around'),
  walkForward('walk_forward'),
  comeBack('come_back'),
  stop('stop'),
  lookAtMe('look_at_me'),

  // The world.
  makeDay('make_day'),
  makeNight('make_night'),
  makeSunset('make_sunset'),
  startRain('start_rain'),
  stopRain('stop_rain'),

  // The camera.
  zoomIn('camera_zoom_in'),
  zoomOut('camera_zoom_out'),
  orbitLeft('camera_orbit_left'),
  orbitRight('camera_orbit_right'),
  topView('camera_top_view'),
  resetCamera('camera_reset'),
  followMe('camera_follow');

  const IslandVerb(this.id);

  /// The id part of an action id: `walk_to` in `walk_to(tree)`.
  final String id;
}
