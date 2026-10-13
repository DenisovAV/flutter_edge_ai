// The Tiny Island action catalog, as data: every option the Decider chooses
// among, with a short description and the phrasings it learns from. English,
// with one Russian phrasing per option for the multilingual moment
// (EmbeddingGemma 2 is multilingual; nothing here is translated at run time).
//
// `island_catalog.dart` expands it: every verb in [genericVerbPhrases] for
// every thing in [islandThingWords], plus [thingVerbPhrases] and
// [globalVerbPhrases]. Placeholders in the generic templates:
//   {t}   the thing's English name        {t2}  its other English name
//   {acc} Russian accusative ("на дерево") {dat} dative ("к дереву")
//   {gen} genitive ("вокруг дерева")       {ins} instrumental ("за деревом")

import 'island_vocabulary.dart';

/// How a thing is named, in English and in the four Russian cases the
/// templates use.
typedef IslandThingWords = ({
  String en,
  String en2,
  String acc,
  String dat,
  String gen,
  String ins,
});

/// A description and the example phrasings of one action (or, for
/// [genericVerbPhrases], of one verb for any thing).
typedef IslandPhrases = ({String description, List<String> examples});

const Map<IslandThing, IslandThingWords> islandThingWords = {
  IslandThing.tree: (
    en: 'oak tree',
    en2: 'tree',
    acc: 'дерево',
    dat: 'дереву',
    gen: 'дерева',
    ins: 'деревом',
  ),
  IslandThing.house: (
    en: 'house',
    en2: 'cottage',
    acc: 'дом',
    dat: 'дому',
    gen: 'дома',
    ins: 'домом',
  ),
  IslandThing.lamp: (
    en: 'street lamp',
    en2: 'lantern',
    acc: 'фонарь',
    dat: 'фонарю',
    gen: 'фонаря',
    ins: 'фонарём',
  ),
  IslandThing.well: (
    en: 'well',
    en2: 'stone well',
    acc: 'колодец',
    dat: 'колодцу',
    gen: 'колодца',
    ins: 'колодцем',
  ),
  IslandThing.chest: (
    en: 'treasure chest',
    en2: 'chest',
    acc: 'сундук',
    dat: 'сундуку',
    gen: 'сундука',
    ins: 'сундуком',
  ),
  IslandThing.flowers: (
    en: 'flower bed',
    en2: 'flowers',
    acc: 'клумбу',
    dat: 'клумбе',
    gen: 'клумбы',
    ins: 'клумбой',
  ),
  IslandThing.rock: (
    en: 'big rock',
    en2: 'boulder',
    acc: 'камень',
    dat: 'камню',
    gen: 'камня',
    ins: 'камнем',
  ),
  IslandThing.bench: (
    en: 'bench',
    en2: 'wooden bench',
    acc: 'скамейку',
    dat: 'скамейке',
    gen: 'скамейки',
    ins: 'скамейкой',
  ),
  IslandThing.campfire: (
    en: 'campfire',
    en2: 'fire pit',
    acc: 'костёр',
    dat: 'костру',
    gen: 'костра',
    ins: 'костром',
  ),
  IslandThing.sign: (
    en: 'signpost',
    en2: 'sign',
    acc: 'табличку',
    dat: 'табличке',
    gen: 'таблички',
    ins: 'табличкой',
  ),
};

/// Verbs that apply to every thing on the island.
const Map<IslandVerb, IslandPhrases> genericVerbPhrases = {
  IslandVerb.walkTo: (
    description: 'Walk to the {t}.',
    examples: [
      'walk to the {t}',
      'go over to the {t2}',
      'head to the {t}',
      'иди к {dat}',
    ],
  ),
  IslandVerb.runTo: (
    description: 'Run to the {t}.',
    examples: [
      'run to the {t}',
      'sprint to the {t2}',
      'hurry over to the {t}',
      'беги к {dat}',
    ],
  ),
  IslandVerb.sneakTo: (
    description: 'Sneak quietly up to the {t}.',
    examples: [
      'sneak up to the {t}',
      'tiptoe quietly to the {t2}',
      'creep slowly toward the {t}',
      'подкрадись к {dat}',
    ],
  ),
  IslandVerb.lookAt: (
    description: 'Turn and look at the {t}.',
    examples: [
      'look at the {t}',
      'turn to face the {t2}',
      'check out the {t}',
      'посмотри на {acc}',
    ],
  ),
  IslandVerb.pointAt: (
    description: 'Point at the {t}.',
    examples: [
      'point at the {t}',
      'show me where the {t2} is',
      'point your finger at the {t}',
      'покажи на {acc}',
    ],
  ),
  IslandVerb.touch: (
    description: 'Walk up to the {t} and touch it.',
    examples: [
      'touch the {t}',
      'put your hand on the {t2}',
      'tap the {t}',
      'потрогай {acc}',
    ],
  ),
  IslandVerb.kick: (
    description: 'Kick the {t}.',
    examples: [
      'kick the {t}',
      'give the {t2} a kick',
      'boot the {t}',
      'пни {acc}',
    ],
  ),
  IslandVerb.hideBehind: (
    description: 'Hide behind the {t}.',
    examples: [
      'hide behind the {t}',
      'take cover behind the {t2}',
      'duck behind the {t}',
      'спрячься за {ins}',
    ],
  ),
  IslandVerb.walkAround: (
    description: 'Walk in a circle around the {t}.',
    examples: [
      'walk around the {t}',
      'circle the {t2}',
      'do a lap around the {t}',
      'обойди вокруг {gen}',
    ],
  ),
  IslandVerb.waveAt: (
    description: 'Wave at the {t}.',
    examples: [
      'wave at the {t}',
      'say hi to the {t2}',
      'wave hello to the {t}',
      'помаши {dat}',
    ],
  ),
  IslandVerb.danceBy: (
    description: 'Dance next to the {t}.',
    examples: [
      'dance next to the {t}',
      'do a little dance by the {t2}',
      'boogie beside the {t}',
      'потанцуй у {gen}',
    ],
  ),
  IslandVerb.cameraOn: (
    description: 'Point the camera at the {t}.',
    examples: [
      'zoom the camera in on the {t}',
      'show me the {t2} up close',
      'focus the camera on the {t}',
      'покажи {acc} крупным планом',
    ],
  ),
};

/// Verbs that belong to one thing.
const List<(IslandVerb, IslandThing, IslandPhrases)> thingVerbPhrases = [
  (
    IslandVerb.climb,
    IslandThing.tree,
    (
      description: 'Climb up into the oak tree.',
      examples: [
        'climb the tree',
        'climb up into the branches of the oak',
        'get up the tree',
        'залезь на дерево',
      ],
    ),
  ),
  (
    IslandVerb.shake,
    IslandThing.tree,
    (
      description: 'Shake the oak tree so its leaves rustle.',
      examples: [
        'shake the tree',
        'shake the branches of the oak',
        'give the tree a good shake',
        'потряси дерево',
      ],
    ),
  ),
  (
    IslandVerb.hug,
    IslandThing.tree,
    (
      description: 'Hug the oak tree.',
      examples: [
        'hug the tree',
        'give the oak a hug',
        'wrap your arms around the tree',
        'обними дерево',
      ],
    ),
  ),
  (
    IslandVerb.sitUnder,
    IslandThing.tree,
    (
      description: 'Sit down in the shade under the oak tree.',
      examples: [
        'sit under the tree',
        'rest in the shade of the oak',
        'take a seat beneath the tree',
        'посиди под деревом',
      ],
    ),
  ),
  (
    IslandVerb.open,
    IslandThing.house,
    (
      description: 'Open the front door of the house.',
      examples: [
        'open the door',
        'open the front door of the house',
        'swing the cottage door open',
        'открой дверь',
      ],
    ),
  ),
  (
    IslandVerb.close,
    IslandThing.house,
    (
      description: 'Close the front door of the house.',
      examples: [
        'close the door',
        'shut the front door',
        'close the house door behind you',
        'закрой дверь',
      ],
    ),
  ),
  (
    IslandVerb.knock,
    IslandThing.house,
    (
      description: 'Knock on the door of the house.',
      examples: [
        'knock on the door',
        'knock knock on the house door',
        'rap on the cottage door',
        'постучи в дверь',
      ],
    ),
  ),
  (
    IslandVerb.goInside,
    IslandThing.house,
    (
      description: 'Go inside the house.',
      examples: [
        'go inside the house',
        'enter the cottage',
        'go home',
        'зайди в дом',
      ],
    ),
  ),
  (
    IslandVerb.comeOut,
    IslandThing.house,
    (
      description: 'Come out of the house.',
      examples: [
        'come out of the house',
        'leave the cottage',
        'step outside',
        'выйди из дома',
      ],
    ),
  ),
  (
    IslandVerb.lightsOn,
    IslandThing.house,
    (
      description: 'Turn on the lights inside the house.',
      examples: [
        'turn on the lights in the house',
        'light up the windows',
        'switch the house lights on',
        'включи свет в доме',
      ],
    ),
  ),
  (
    IslandVerb.lightsOff,
    IslandThing.house,
    (
      description: 'Turn off the lights inside the house.',
      examples: [
        'turn off the lights in the house',
        'make the windows dark',
        'switch the house lights off',
        'выключи свет в доме',
      ],
    ),
  ),
  (
    IslandVerb.turnOn,
    IslandThing.lamp,
    (
      description: 'Turn on the street lamp.',
      examples: [
        'turn on the lamp',
        'switch the lantern on',
        'light the street lamp',
        'включи фонарь',
      ],
    ),
  ),
  (
    IslandVerb.turnOff,
    IslandThing.lamp,
    (
      description: 'Turn off the street lamp.',
      examples: [
        'turn off the lamp',
        'switch the lantern off',
        'put out the street light',
        'выключи фонарь',
      ],
    ),
  ),
  (
    IslandVerb.drawWater,
    IslandThing.well,
    (
      description: 'Draw a bucket of water from the well.',
      examples: [
        'draw water from the well',
        'fill the bucket at the well',
        'get some water',
        'набери воды из колодца',
      ],
    ),
  ),
  (
    IslandVerb.throwCoin,
    IslandThing.well,
    (
      description: 'Throw a coin into the well and make a wish.',
      examples: [
        'throw a coin in the well',
        'make a wish at the well',
        'toss a penny into the well',
        'брось монетку в колодец',
      ],
    ),
  ),
  (
    IslandVerb.peekInto,
    IslandThing.well,
    (
      description: 'Lean over and look down into the well.',
      examples: [
        'look down into the well',
        'peek inside the well',
        'how deep is the well',
        'загляни в колодец',
      ],
    ),
  ),
  (
    IslandVerb.open,
    IslandThing.chest,
    (
      description: 'Open the treasure chest.',
      examples: [
        'open the chest',
        'open the treasure chest',
        'lift the lid of the chest',
        'открой сундук',
      ],
    ),
  ),
  (
    IslandVerb.close,
    IslandThing.chest,
    (
      description: 'Close the treasure chest.',
      examples: [
        'close the chest',
        'shut the lid of the treasure chest',
        'close the treasure box',
        'закрой сундук',
      ],
    ),
  ),
  (
    IslandVerb.takeTreasure,
    IslandThing.chest,
    (
      description: 'Take the gold out of the treasure chest.',
      examples: [
        'take the treasure',
        'grab the gold from the chest',
        'loot the chest',
        'достань сокровища из сундука',
      ],
    ),
  ),
  (
    IslandVerb.water,
    IslandThing.flowers,
    (
      description: 'Water the flowers in the flower bed.',
      examples: [
        'water the flowers',
        'give the flower bed some water',
        'water the plants',
        'полей цветы',
      ],
    ),
  ),
  (
    IslandVerb.pick,
    IslandThing.flowers,
    (
      description: 'Pick a flower from the flower bed.',
      examples: [
        'pick a flower',
        'pluck a flower from the bed',
        'get me a flower',
        'сорви цветок',
      ],
    ),
  ),
  (
    IslandVerb.smell,
    IslandThing.flowers,
    (
      description: 'Smell the flowers.',
      examples: [
        'smell the flowers',
        'sniff the roses',
        'stop and smell the flowers',
        'понюхай цветы',
      ],
    ),
  ),
  (
    IslandVerb.plant,
    IslandThing.flowers,
    (
      description: 'Plant a new seed in the flower bed.',
      examples: [
        'plant a seed',
        'plant something new in the garden',
        'sow some seeds in the flower bed',
        'посади семечко',
      ],
    ),
  ),
  (
    IslandVerb.sitOn,
    IslandThing.rock,
    (
      description: 'Sit on the big rock.',
      examples: [
        'sit on the rock',
        'take a seat on the big stone',
        'perch on the boulder',
        'сядь на камень',
      ],
    ),
  ),
  (
    IslandVerb.climb,
    IslandThing.rock,
    (
      description: 'Climb on top of the big rock.',
      examples: [
        'climb onto the rock',
        'stand on top of the boulder',
        'get up on the big stone',
        'залезь на камень',
      ],
    ),
  ),
  (
    IslandVerb.push,
    IslandThing.rock,
    (
      description: 'Try to push the big rock.',
      examples: [
        'push the rock',
        'try to move the boulder',
        'shove the big stone',
        'толкни камень',
      ],
    ),
  ),
  (
    IslandVerb.sitOn,
    IslandThing.bench,
    (
      description: 'Sit on the bench.',
      examples: [
        'sit on the bench',
        'take a seat on the bench',
        'have a rest on the wooden bench',
        'сядь на скамейку',
      ],
    ),
  ),
  (
    IslandVerb.lieOn,
    IslandThing.bench,
    (
      description: 'Lie down on the bench for a nap.',
      examples: [
        'lie down on the bench',
        'take a nap on the bench',
        'stretch out on the wooden bench',
        'приляг на скамейку',
      ],
    ),
  ),
  (
    IslandVerb.light,
    IslandThing.campfire,
    (
      description: 'Light the campfire.',
      examples: [
        'light the campfire',
        'start a fire',
        'make a fire in the fire pit',
        'разожги костёр',
      ],
    ),
  ),
  (
    IslandVerb.putOut,
    IslandThing.campfire,
    (
      description: 'Put out the campfire.',
      examples: [
        'put out the fire',
        'extinguish the campfire',
        'douse the flames',
        'потуши костёр',
      ],
    ),
  ),
  (
    IslandVerb.warmUp,
    IslandThing.campfire,
    (
      description: 'Warm up by the campfire.',
      examples: [
        'warm your hands by the fire',
        'warm up at the campfire',
        'I am cold, get warm by the fire',
        'погрейся у костра',
      ],
    ),
  ),
  (
    IslandVerb.roast,
    IslandThing.campfire,
    (
      description: 'Roast marshmallows over the campfire.',
      examples: [
        'roast marshmallows',
        'toast a marshmallow over the fire',
        'cook something on the campfire',
        'пожарь зефир на костре',
      ],
    ),
  ),
  (
    IslandVerb.read,
    IslandThing.sign,
    (
      description: 'Read the signpost.',
      examples: [
        'read the sign',
        'what does the signpost say',
        'read what is written on the sign',
        'прочитай табличку',
      ],
    ),
  ),
];

/// Actions with no thing: the character anywhere, the world, the camera.
const Map<IslandVerb, IslandPhrases> globalVerbPhrases = {
  IslandVerb.jump: (
    description: 'Jump up in the air.',
    examples: ['jump', 'hop up and down', 'jump as high as you can', 'прыгни'],
  ),
  IslandVerb.dance: (
    description: 'Dance on the spot.',
    examples: ['dance', 'show me your moves', 'do a happy dance', 'потанцуй'],
  ),
  IslandVerb.wave: (
    description: 'Wave hello to the viewer.',
    examples: ['wave', 'wave hello', 'say hello to me', 'помаши мне'],
  ),
  IslandVerb.sleep: (
    description: 'Lie down on the ground and go to sleep.',
    examples: [
      'go to sleep',
      'take a nap',
      'lie down and rest',
      'ложись спать',
    ],
  ),
  IslandVerb.wakeUp: (
    description: 'Wake up and get back on your feet.',
    examples: [
      'wake up',
      'rise and shine',
      'get up, it is morning',
      'проснись',
    ],
  ),
  IslandVerb.sitDown: (
    description: 'Sit down on the ground.',
    examples: [
      'sit down',
      'have a seat on the grass',
      'sit on the ground',
      'сядь',
    ],
  ),
  IslandVerb.standUp: (
    description: 'Stand up.',
    examples: ['stand up', 'get on your feet', 'get up', 'встань'],
  ),
  IslandVerb.crouch: (
    description: 'Crouch down low.',
    examples: ['crouch', 'duck down', 'get low', 'пригнись'],
  ),
  IslandVerb.spin: (
    description: 'Spin around in a circle.',
    examples: [
      'spin around',
      'turn around in a full circle',
      'do a pirouette',
      'покружись',
    ],
  ),
  IslandVerb.nod: (
    description: 'Nod yes.',
    examples: ['nod', 'say yes', 'nod your head', 'кивни'],
  ),
  IslandVerb.shakeHead: (
    description: 'Shake your head no.',
    examples: ['shake your head', 'say no', 'nope', 'покачай головой'],
  ),
  IslandVerb.cheer: (
    description: 'Cheer and celebrate.',
    examples: ['cheer', 'celebrate', 'hooray, we did it', 'порадуйся'],
  ),
  IslandVerb.turnLeft: (
    description: 'Turn to the left.',
    examples: [
      'turn left',
      'face left',
      'rotate to your left',
      'повернись налево',
    ],
  ),
  IslandVerb.turnRight: (
    description: 'Turn to the right.',
    examples: [
      'turn right',
      'face right',
      'rotate to your right',
      'повернись направо',
    ],
  ),
  IslandVerb.turnAround: (
    description: 'Turn around and face the other way.',
    examples: [
      'turn around',
      'face the other way',
      'turn your back',
      'развернись',
    ],
  ),
  IslandVerb.walkForward: (
    description: 'Walk a few steps forward.',
    examples: [
      'walk forward',
      'take a few steps forward',
      'move ahead a bit',
      'иди вперёд',
    ],
  ),
  IslandVerb.comeBack: (
    description: 'Walk back to the middle of the island.',
    examples: [
      'come back to the middle',
      'go back to the center of the island',
      'return to where you started',
      'вернись в центр',
    ],
  ),
  IslandVerb.stop: (
    description: 'Stop and stand still.',
    examples: ['stop', 'stand still', 'freeze', 'стой'],
  ),
  IslandVerb.lookAtMe: (
    description: 'Turn and look at the viewer.',
    examples: [
      'look at me',
      'face the camera',
      'turn towards me',
      'посмотри на меня',
    ],
  ),
  IslandVerb.makeDay: (
    description: 'Make it daytime: the sun comes up.',
    examples: [
      'make it day',
      'good morning, bring out the sun',
      'switch to daytime',
      'сделай день',
    ],
  ),
  IslandVerb.makeNight: (
    description: 'Make it night: the sky goes dark.',
    examples: [
      'make it night',
      'turn off the sun',
      'it is night time',
      'сделай ночь',
    ],
  ),
  IslandVerb.makeSunset: (
    description: 'Make it sunset: an orange evening sky.',
    examples: [
      'make it sunset',
      'evening please',
      'show me a sunset',
      'сделай закат',
    ],
  ),
  IslandVerb.startRain: (
    description: 'Make it rain on the island.',
    examples: [
      'make it rain',
      'start the rain',
      'let it pour',
      'пусть пойдёт дождь',
    ],
  ),
  IslandVerb.stopRain: (
    description: 'Stop the rain and clear the sky.',
    examples: [
      'stop the rain',
      'clear skies please',
      'make the weather nice again',
      'останови дождь',
    ],
  ),
  IslandVerb.zoomIn: (
    description: 'Move the camera closer.',
    examples: [
      'zoom in',
      'get closer',
      'move the camera in',
      'приблизь камеру',
    ],
  ),
  IslandVerb.zoomOut: (
    description: 'Move the camera farther away.',
    examples: [
      'zoom out',
      'pull the camera back',
      'show more of the scene',
      'отдали камеру',
    ],
  ),
  IslandVerb.orbitLeft: (
    description: 'Rotate the camera to the left around the island.',
    examples: [
      'rotate the camera left',
      'orbit to the left',
      'swing the view left',
      'поверни камеру влево',
    ],
  ),
  IslandVerb.orbitRight: (
    description: 'Rotate the camera to the right around the island.',
    examples: [
      'rotate the camera right',
      'orbit to the right',
      'swing the view right',
      'поверни камеру вправо',
    ],
  ),
  IslandVerb.topView: (
    description: 'Look down at the island from above.',
    examples: [
      'top view',
      'show the island from above',
      'bird\'s eye view',
      'вид сверху',
    ],
  ),
  IslandVerb.resetCamera: (
    description: 'Reset the camera to show the whole island.',
    examples: [
      'reset the camera',
      'show the whole island',
      'default view',
      'покажи весь остров',
    ],
  ),
  IslandVerb.followMe: (
    description: 'Make the camera follow the character.',
    examples: [
      'follow the character with the camera',
      'camera, follow me',
      'keep the camera on the hero',
      'следи за мной камерой',
    ],
  ),
};
