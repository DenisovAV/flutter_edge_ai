// Request sets shared by the Tiny Island device tests and the voice-clip
// generator (tools/generate_island_voice_clips.dart). Pure Dart, no imports,
// so a host script can read them with `dart run`.
//
// The held-out (calibration) requests live in the app itself:
// lib/tiny_island/island_held_out_requests.dart.

/// A request the screen test sends, the action it must choose (null: it must
/// abstain), and how long the island needs to play it (and the screenshot it
/// takes, if any).
typedef TinyIslandScreenCase = ({
  String request,
  String? expect,
  double play,
  String? shot,
});

/// The screen test's requests (integration_test/tiny_island_test.dart).
/// None of them is an option's example or description, nor a held-out
/// calibration request (the screen test checks that first).
const tinyIslandScreenCases = <TinyIslandScreenCase>[
  (
    request: 'stroll over to the well',
    expect: 'walk_to(well)',
    play: 4,
    shot: null,
  ),
  (
    request: 'crack open the treasure chest',
    expect: 'open(chest)',
    play: 6,
    shot: 'chest',
  ),
  (
    request: 'pour some water on the flowers',
    expect: 'water(flowers)',
    play: 5,
    shot: null,
  ),
  (
    request: 'what is the capital of France?',
    expect: null,
    play: 1.2,
    shot: 'abstain',
  ),
  (request: 'make the sun set', expect: 'make_sunset', play: 2.5, shot: null),
  (
    request: 'turn the lantern on',
    expect: 'turn_on(lamp)',
    play: 6,
    shot: null,
  ),
  (
    request: 'build a campfire',
    expect: 'light(campfire)',
    play: 5,
    shot: 'night',
  ),
  (
    request: 'grab a seat on the bench',
    expect: 'sit_on(bench)',
    play: 5,
    shot: null,
  ),
  (request: 'geh zum Baum', expect: 'walk_to(tree)', play: 5, shot: null),
  (request: 'I want it to rain', expect: 'start_rain', play: 3, shot: 'rain'),
  (request: 'dance a little jig', expect: 'dance', play: 6, shot: null),
  (
    request: 'do a dance at the fire pit',
    expect: 'dance_by(campfire)',
    play: 6,
    shot: null,
  ),
  (request: 'tell me a joke', expect: null, play: 2.5, shot: null),
  (
    request: 'climb up the oak tree',
    expect: 'climb(tree)',
    play: 5,
    shot: null,
  ),
  (request: 'how much is two plus two', expect: null, play: 2.5, shot: null),
  (
    request: 'close the lid of the chest',
    expect: 'close(chest)',
    play: 5,
    shot: null,
  ),
  (
    request: 'turn out the lights in the cottage',
    expect: 'lights_off(house)',
    play: 4,
    shot: null,
  ),
];

/// Requests about nothing on the island. None of them is a screen-test case
/// or a suggestion chip.
const tinyIslandOutOfScopeRequests = [
  'what is the weather like in Berlin tomorrow',
  'what is 17 times 23',
  'who won the football match yesterday',
  'how are you today',
  'what time is it',
  'translate good morning into Spanish',
  'set an alarm for seven',
  'call my mother',
  'what is the capital of Australia',
  'recommend a good book',
  'how do I bake bread',
  'what is the meaning of life',
  'play some jazz music',
  'send an email to my boss',
  'how many legs does a spider have',
  'what is the square root of 144',
  'book a table for two tonight',
  'order a pizza',
  'remind me to buy milk',
  'explain quantum computing',
  'write a poem about the sea',
  'how tall is Mount Everest',
  'convert 10 miles to kilometres',
  'who painted the Mona Lisa',
  'what is your favourite colour',
  'what is the forecast for the weekend',
  'what is five plus seven',
  'tell me a funny story',
  'wie spät ist es',
  'wer ist der Bundeskanzler',
];

/// The German requests among the held-out, out-of-scope and screen requests;
/// every other one is English. The voice-clip generator speaks these with a
/// German voice (and refuses a text here that none of the lists has).
const tinyIslandGermanRequests = {
  'mach das Licht im Haus an',
  'spring hoch',
  'lass es regnen',
  'wie spät ist es',
  'wer ist der Bundeskanzler',
  'geh zum Baum',
};
