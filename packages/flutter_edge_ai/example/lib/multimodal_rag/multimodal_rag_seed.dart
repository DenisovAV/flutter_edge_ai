/// The sample knowledge base the Multimodal RAG screen starts with: short notes,
/// photos (the EmbeddingGemma 2 sample scenes) and voice memos spoken by
/// Matcha-TTS (integration_test/tools/generate_knowledge_memos.dart).
///
/// Photos and memos carry no caption on purpose: a photo is found by what is
/// in it, a memo by what is said in it — EmbeddingGemma 2 embeds the pixels
/// and the sound, not a title.
library;

/// A seeded markdown note.
final class SeedNote {
  const SeedNote({required this.id, required this.title, required this.body});

  final String id;
  final String title;
  final String body;
}

/// A seeded photo: an EmbeddingGemma 2 sample scene (`assets/eg2_vision/`)
/// or one of this screen's own (`assets/knowledge/photos/`), under a
/// camera-style name.
final class SeedPhoto {
  const SeedPhoto({required this.id, required this.title, required this.asset});

  final String id;
  final String title;
  final String asset;
}

/// A seeded voice memo: a 16 kHz mono WAV under `assets/knowledge/memos/`.
final class SeedMemo {
  const SeedMemo({
    required this.id,
    required this.title,
    required this.assetName,
    required this.duration,
  });

  final String id;
  final String title;
  final String assetName;
  final Duration duration;

  String get asset => 'assets/knowledge/memos/$assetName';
}

const kSeedNotes = <SeedNote>[
  SeedNote(
    id: 'note-london',
    title: 'London trip',
    body:
        'The flight leaves Friday at 10:40 from Terminal 5. Hotel near '
        'Shoreditch, check-in from 3 pm. Keep every taxi receipt: finance '
        'pays airport rides back up to 40 pounds.',
  ),
  SeedNote(
    id: 'note-kitchen',
    title: 'Kitchen renovation',
    body:
        'Electrician booked for Thursday morning. Budget for the new lights: '
        '600 dollars. Still to choose: pendant lamps over the island and the '
        'color of the backsplash tiles.',
  ),
  SeedNote(
    id: 'note-q3',
    title: 'Q3 planning',
    body:
        'Revenue grew every quarter this year and Q3 was the strongest. Next '
        'quarter: faster onboarding, a clearer pricing page and the partner '
        'program.',
  ),
  SeedNote(
    id: 'note-pasta',
    title: 'Lemon pasta',
    body:
        'Spaghetti, zest of two lemons, parmesan, butter, black pepper and a '
        'handful of basil. Loosen with a ladle of pasta water. Twenty minutes.',
  ),
  SeedNote(
    id: 'note-bookclub',
    title: 'Book club',
    body:
        'Next meeting on the 24th at Anna\'s place. We are reading Klara and '
        'the Sun: finish the first four chapters and bring a question.',
  ),
  SeedNote(
    id: 'note-running',
    title: 'Half-marathon plan',
    body:
        'Long run every Sunday, building from 12 to 18 km. Easy runs on '
        'Tuesday and Thursday, intervals on Wednesday, rest on Friday.',
  ),
  SeedNote(
    id: 'note-offsite',
    title: 'Team offsite',
    body:
        'Two days in October for eight people, somewhere reachable by train. '
        'Ideas so far: a hike, a board-game night and a roadmap workshop.',
  ),
  SeedNote(
    id: 'note-car',
    title: 'Car service',
    body:
        'Winter tires go on before November. The garage on Elm Street is open '
        'on Saturdays until 2 pm; ask them about the rattling brake.',
  ),
];

const kSeedPhotos = <SeedPhoto>[
  // Drawn for this screen (integration_test/tools/
  // generate_knowledge_photos.py): its TOTAL is the one place the amount is.
  SeedPhoto(
    id: 'photo-0412',
    title: 'IMG_0412',
    asset: 'assets/knowledge/photos/taxi_receipt.png',
  ),
  SeedPhoto(
    id: 'photo-0388',
    title: 'IMG_0388',
    asset: 'assets/eg2_vision/grocery_receipt.png',
  ),
  SeedPhoto(
    id: 'photo-0291',
    title: 'IMG_0291',
    asset: 'assets/eg2_vision/pie_chart.png',
  ),
  SeedPhoto(
    id: 'photo-0290',
    title: 'IMG_0290',
    asset: 'assets/eg2_vision/bar_chart.png',
  ),
  SeedPhoto(
    id: 'photo-0307',
    title: 'IMG_0307',
    asset: 'assets/eg2_vision/line_chart.png',
  ),
  SeedPhoto(
    id: 'photo-0455',
    title: 'IMG_0455',
    asset: 'assets/eg2_vision/stop_sign.png',
  ),
  SeedPhoto(
    id: 'photo-0476',
    title: 'IMG_0476',
    asset: 'assets/eg2_vision/house_scene.png',
  ),
];

const kSeedMemos = <SeedMemo>[
  SeedMemo(
    id: 'memo-kitchen',
    title: 'Voice memo 1',
    assetName: 'memo_1.wav',
    duration: Duration(milliseconds: 4600),
  ),
  SeedMemo(
    id: 'memo-flight',
    title: 'Voice memo 2',
    assetName: 'memo_2.wav',
    duration: Duration(milliseconds: 4590),
  ),
  SeedMemo(
    id: 'memo-groceries',
    title: 'Voice memo 3',
    assetName: 'memo_3.wav',
    duration: Duration(milliseconds: 3540),
  ),
  SeedMemo(
    id: 'memo-offsite',
    title: 'Voice memo 4',
    assetName: 'memo_4.wav',
    duration: Duration(milliseconds: 4230),
  ),
  SeedMemo(
    id: 'memo-mom',
    title: 'Voice memo 5',
    assetName: 'memo_5.wav',
    duration: Duration(milliseconds: 3550),
  ),
  SeedMemo(
    id: 'memo-dentist',
    title: 'Voice memo 6',
    assetName: 'memo_6.wav',
    duration: Duration(milliseconds: 3340),
  ),
];
