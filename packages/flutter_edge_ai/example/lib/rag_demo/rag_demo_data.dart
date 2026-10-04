/// Sample documents for RAG demo.
///
/// Each document has a `category` so the demo can illustrate qdrant-edge's
/// payload `Filter` (must / mustNot) on top of semantic search.
const List<Map<String, String>> sampleDocuments = [
  {
    'id': 'flutter_intro',
    'category': 'flutter',
    'content':
        'Flutter is an open-source UI framework by Google for building natively compiled applications for mobile, web, and desktop from a single codebase.',
  },
  {
    'id': 'dart_language',
    'category': 'dart',
    'content':
        'Dart is a client-optimized programming language for fast apps on multiple platforms. It is developed by Google and used to build Flutter applications.',
  },
  {
    'id': 'flutter_widgets',
    'category': 'flutter',
    'content':
        'In Flutter, everything is a widget. Widgets describe what their view should look like given their current configuration and state.',
  },
  {
    'id': 'flutter_hot_reload',
    'category': 'flutter',
    'content':
        'Flutter hot reload helps you quickly experiment, build UIs, add features, and fix bugs by injecting updated source code into the running Dart VM.',
  },
  {
    'id': 'flutter_state',
    'category': 'flutter',
    'content':
        'Flutter uses setState() for simple state management in StatefulWidget. For complex apps, consider using Provider, Riverpod, or BLoC pattern.',
  },
  {
    'id': 'flutter_platforms',
    'category': 'flutter',
    'content':
        'Flutter supports iOS, Android, web, Windows, macOS, and Linux platforms, allowing developers to create cross-platform applications efficiently.',
  },
  {
    'id': 'dart_null_safety',
    'category': 'dart',
    'content':
        'Dart null safety helps catch null reference errors at compile time. Use nullable types with ? and null-aware operators like ?? and ?. for safer code.',
  },
  {
    'id': 'flutter_performance',
    'category': 'flutter',
    'content':
        'Flutter achieves high performance by compiling to native ARM code and using Skia graphics engine for rendering at 60fps or higher.',
  },
];

/// The categories visible in `sampleDocuments`. Drives the filter UI.
const List<String> sampleCategories = ['flutter', 'dart'];
