import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/log.dart';

/// Where captures are written. Tests inject a temp directory.
final captureDirProvider = FutureProvider<Directory>((ref) async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/captures');
});

/// One saved page: the rendered HTML as the person saw it, plus what the
/// recipe made of it. Captures are how real pages reach the test suite
/// without any automated loading of the live sites (TQ70/71 round): the
/// person browses, taps Capture, and the file can be pulled off the device.
class PageCapture {
  const PageCapture({
    required this.id,
    required this.siteId,
    required this.url,
    required this.title,
    required this.capturedAt,
    required this.htmlPath,
    required this.htmlBytes,
    this.check,
    this.task,
  });

  /// File stem shared by the `.html` and `.json` files.
  final String id;

  /// The curated site the page belongs to, or `other`.
  final String siteId;
  final String url;
  final String title;
  final DateTime capturedAt;
  final String htmlPath;

  /// Size of the HTML file on disk (UTF-8 bytes, not characters).
  final int htmlBytes;

  /// The recipe's verdict on this page at capture time, when a recipe applied.
  final SelfCheck? check;

  /// The test task this capture answers, if the person picked one.
  final String? task;

  /// "412 KB", for lists.
  String get sizeLabel => '${(htmlBytes / 1024).round()} KB';

  /// Local date and time to the minute, for lists.
  String get capturedLabel => capturedAt.toLocal().toString().substring(0, 16);

  Map<String, Object?> toJson() => {
    'id': id,
    'siteId': siteId,
    'url': url,
    'title': title,
    'capturedAt': capturedAt.toIso8601String(),
    'htmlPath': htmlPath,
    'htmlBytes': htmlBytes,
    if (check != null) 'check': check!.toJson(),
    if (task != null) 'task': task,
  };

  /// Restores a capture's metadata from its `.json` file.
  factory PageCapture.fromJson(Map<String, Object?> j) => PageCapture(
    id: j['id'] as String,
    siteId: j['siteId'] as String,
    url: j['url'] as String,
    title: j['title'] as String? ?? '',
    capturedAt: DateTime.parse(j['capturedAt'] as String),
    htmlPath: j['htmlPath'] as String,
    htmlBytes: (j['htmlBytes'] as num?)?.toInt() ?? 0,
    check: j['check'] is Map
        ? SelfCheck.fromJson((j['check'] as Map).cast<String, Object?>())
        : null,
    task: j['task'] as String?,
  );
}

final captureStoreProvider = AsyncNotifierProvider<CaptureStore, List<PageCapture>>(
  CaptureStore.new,
);

/// The saved captures, newest first. A capture whose metadata cannot be read
/// is skipped and logged rather than failing the whole list.
class CaptureStore extends AsyncNotifier<List<PageCapture>> {
  /// Characters of the ISO timestamp kept in the id: date and time to the
  /// second, with the millisecond appended separately so two captures in one
  /// second do not overwrite each other.
  static final _idJunk = RegExp(r'[:.\-T]');

  @override
  Future<List<PageCapture>> build() async {
    final dir = await ref.watch(captureDirProvider.future);
    if (!await dir.exists()) return const [];
    final out = <PageCapture>[];
    await for (final f in dir.list()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          out.add(
            PageCapture.fromJson(
              (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>(),
            ),
          );
        } on Exception catch (e) {
          logDev('capture ${f.path} skipped: $e');
        }
      }
    }
    out.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return out;
  }

  /// Save [html] for [url] under the site it belongs to. [check] is the
  /// recipe's verdict on this very page, so the capture carries its own
  /// evidence of whether the recipe still works.
  Future<PageCapture> save({
    required String siteId,
    required String url,
    required String title,
    required String html,
    SelfCheck? check,
    String? task,
  }) async {
    final dir = await ref.read(captureDirProvider.future);
    await dir.create(recursive: true);
    final stamp = DateTime.now();
    final id = '$siteId-${stamp.toIso8601String().replaceAll(_idJunk, '').substring(0, 17)}';
    final htmlFile = File('${dir.path}/$id.html');
    await htmlFile.writeAsString(html);
    final capture = PageCapture(
      id: id,
      siteId: siteId,
      url: url,
      title: title,
      capturedAt: stamp,
      htmlPath: htmlFile.path,
      htmlBytes: utf8.encode(html).length,
      check: check,
      task: task,
    );
    await File('${dir.path}/$id.json').writeAsString(jsonEncode(capture.toJson()));
    state = AsyncData([capture, ...?state.value]);
    return capture;
  }

  Future<void> delete(PageCapture c) async {
    final html = File(c.htmlPath);
    final json = File(c.htmlPath.replaceFirst(RegExp(r'\.html$'), '.json'));
    for (final f in [html, json]) {
      if (await f.exists()) await f.delete();
    }
    state = AsyncData([...?state.value?.where((x) => x.id != c.id)]);
  }
}

/// One page worth capturing, with the steps to reach it.
class CaptureTask {
  const CaptureTask({
    required this.id,
    required this.siteId,
    required this.title,
    required this.steps,
  });
  final String id;
  final String siteId;
  final String title;
  final List<String> steps;
}

/// The pages worth capturing, as instructions a person can follow when they
/// have a minute. Each becomes one fixture for the recipe tests. The chip
/// names in the steps are the labels on the filters card.
const List<CaptureTask> captureTasks = [
  CaptureTask(
    id: 'echopark-suv-50k',
    siteId: 'echopark',
    title: 'EchoPark: SUVs under \$50k',
    steps: [
      'Pick "Look on: EchoPark", tap SUV and Under \$50k on the filters card.',
      'Wait until the cards show photos (scroll down once so they load).',
      'Tap Capture.',
    ],
  ),
  CaptureTask(
    id: 'echopark-detail',
    siteId: 'echopark',
    title: 'EchoPark: one vehicle page',
    steps: ['On any EchoPark results page, tap a car to open its page.', 'Tap Capture.'],
  ),
  CaptureTask(
    id: 'cars-coupe-40k',
    siteId: 'cars',
    title: 'Cars.com: coupes under \$40k',
    steps: [
      'Pick "Look on: Cars.com", tap Sports / coupe and Under \$50k (the card has no \$40k rung).',
      'If Cars.com asks you to confirm you are a person, tick its box.',
      'Scroll down once so photos load, then tap Capture.',
    ],
  ),
  CaptureTask(
    id: 'cars-detail',
    siteId: 'cars',
    title: 'Cars.com: one vehicle page',
    steps: ['On any Cars.com results page, tap a car to open its page.', 'Tap Capture.'],
  ),
];
