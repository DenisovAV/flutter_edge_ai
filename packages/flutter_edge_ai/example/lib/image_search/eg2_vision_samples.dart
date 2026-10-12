/// The sample photos bundled with the example (`assets/eg2_vision/`): ten
/// scenes drawn by `integration_test/tools/generate_eg2_vision_images.py`
/// (nothing to license), each with the caption EmbeddingGemma 2 should find
/// it by. The Image Search screen offers them where no photo library is at
/// hand (desktop, emulators, test devices), and the device suites use them.
library;

/// Scene name → a caption that describes it.
const eg2VisionSampleCaptions = <String, String>{
  'circle': 'a red circle on a white background',
  'square': 'a blue square on a white background',
  'triangle': 'a green triangle on a white background',
  'bar_chart': 'a bar chart of quarterly revenue',
  'pie_chart': 'a pie chart showing market share',
  'line_chart': 'a line chart of temperature by month',
  'grocery_receipt':
      'a grocery store receipt listing milk, bread, eggs and apples',
  'taxi_receipt': 'a taxi receipt with an airport fee',
  'stop_sign': 'a red stop sign',
  'house_scene': 'a small house on green grass under a yellow sun',
};

/// The asset key of a scene's PNG.
String eg2VisionSampleAsset(String scene) => 'assets/eg2_vision/$scene.png';

/// The asset key of a scene's near-duplicate (resized to 75 %, JPEG q70).
String eg2VisionDuplicateAsset(String scene) =>
    'assets/eg2_vision/${scene}_dup.jpg';
