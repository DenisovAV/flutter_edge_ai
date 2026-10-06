import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

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

  final String id;
  final String siteId;
  final String url;
  final String title;
  final DateTime capturedAt;
  final String htmlPath;
  final int htmlBytes;
  final SelfCheck? check;

  /// The test task this capture answers, if the person picked one.
  final String? task;

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

  static PageCapture fromJson(Map<String, Object?> j) => PageCapture(
    id: j['id'] as String,
    siteId: j['siteId'] as String,
    url: j['url'] as String,
    title: j['title'] as String? ?? '',
    capturedAt: DateTime.parse(j['capturedAt'] as String),
    htmlPath: j['htmlPath'] as String,
    htmlBytes: (j['htmlBytes'] as num?)?.toInt() ?? 0,
    check: j['check'] is Map
        ? () {
            final c = (j['check'] as Map).cast<String, Object?>();
            return SelfCheck(
              ok: c['ok'] == true,
              cardsFound: (c['cardsFound'] as num?)?.toInt() ?? 0,
              withPrice: (c['withPrice'] as num?)?.toInt() ?? 0,
              withImage: (c['withImage'] as num?)?.toInt() ?? 0,
              pageTotal: (c['pageTotal'] as num?)?.toInt(),
              problems: ((c['problems'] as List?) ?? const []).cast<String>(),
            );
          }()
        : null,
    task: j['task'] as String?,
  );
}

final captureStoreProvider = AsyncNotifierProvider<CaptureStore, List<PageCapture>>(
  CaptureStore.new,
);

class CaptureStore extends AsyncNotifier<List<PageCapture>> {
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
        } catch (e) {
          debugPrint('[motormind] capture ${f.path}: $e');
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
    final id =
        '$siteId-${stamp.toIso8601String().replaceAll(RegExp(r'[:.]'), '').substring(0, 15)}';
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
    final dir = await ref.read(captureDirProvider.future);
    for (final ext in const ['html', 'json']) {
      final f = File('${dir.path}/${c.id}.$ext');
      if (await f.exists()) await f.delete();
    }
    state = AsyncData([...?state.value?.where((x) => x.id != c.id)]);
  }
}

/// The pages worth capturing, written as instructions a person can follow
/// when they have a minute. Each becomes one fixture for the recipe tests.
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

const captureTasks = [
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
      'Pick "Look on: Cars.com", tap Sports / coupe and Under \$50k.',
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
