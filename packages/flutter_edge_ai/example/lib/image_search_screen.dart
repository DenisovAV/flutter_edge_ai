import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'embedding_models_screen.dart';
import 'image_search/image_search_app_dependencies.dart';
import 'image_search/image_search_controller.dart';
import 'image_search/photo_store.dart';

/// Image search with EmbeddingGemma 2 on the device: photos go into a RAG
/// image index (flutter_edge_ai_rag over SQLite), then a text finds photos
/// (text → image) and a photo finds similar ones (image → image).
///
/// The model is the ACTIVE embedder, chosen on the Embedding Models list —
/// EmbeddingGemma 2 Text + Vision (440M); the 270M has no vision encoder and
/// is refused with the reason. Every platform: on the web the model runs on
/// WebGPU through `@litert-lm/core` (the browser needs WebGPU; there is no CPU
/// path for these bundles there), about 0.33 s per photo on a Tesla T4.
class ImageSearchScreen extends StatefulWidget {
  const ImageSearchScreen({super.key, this.dependencies, this.onChooseModel});

  /// Defaults to [imageSearchAppDependencies]; tests pass fakes.
  final ImageSearchDependencies? dependencies;

  /// Opens the model list. Defaults to pushing [EmbeddingModelsScreen].
  final Future<void> Function(BuildContext context)? onChooseModel;

  @override
  State<ImageSearchScreen> createState() => _ImageSearchScreenState();
}

class _ImageSearchScreenState extends State<ImageSearchScreen> {
  late final ImageSearchDependencies _deps =
      widget.dependencies ?? imageSearchAppDependencies();
  late final ImageSearchController _controller = ImageSearchController(_deps);
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    // open() keeps every failure in the controller's state, for the screen.
    unawaited(_controller.open());
  }

  @override
  void dispose() {
    _controller.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _chooseModel() async {
    final open = widget.onChooseModel;
    if (open != null) {
      await open(context);
    } else {
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(builder: (_) => const EmbeddingModelsScreen()),
      );
    }
    if (!mounted) return;
    await _controller.open();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Image Search'),
        backgroundColor: const Color(0xFF0b2351),
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = _controller;
    final ready = c.status == ImageSearchStatus.ready;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ModelCard(controller: c),
        if (c.error case final error?) ...[
          const SizedBox(height: 12),
          _ErrorCard(
            message: error,
            onChooseModel: c.suggestModelList ? _chooseModel : null,
          ),
        ],
        if (c.addFailures.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ErrorCard(
            cardKey: const Key('image-search-add-failures'),
            message: 'Not added:\n${c.addFailures.join('\n')}',
          ),
        ],
        if (c.busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          if (c.progress case final progress?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(progress, style: _muted),
            ),
        ],
        if (ready) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('image-search-add-samples'),
                onPressed: c.busy ? null : c.addSamples,
                icon: const Icon(Icons.collections),
                label: const Text('Add sample photos'),
              ),
              OutlinedButton.icon(
                key: const Key('image-search-add-photos'),
                onPressed: c.busy ? null : c.addPhotos,
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text('Add photos…'),
              ),
              TextButton.icon(
                key: const Key('image-search-clear'),
                onPressed: c.busy || c.documentCount == 0 ? null : c.clearIndex,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${c.documentCount} photo${c.documentCount == 1 ? '' : 's'} in '
            'the index',
            key: const Key('image-search-count'),
            style: _muted,
          ),
          if (c.added.isNotEmpty)
            _AddedStrip(controller: c, store: _deps.photos),
          const SizedBox(height: 16),
          TextField(
            key: const Key('image-search-query'),
            controller: _query,
            enabled: !c.busy,
            textInputAction: TextInputAction.search,
            onSubmitted: c.searchText,
            decoration: InputDecoration(
              labelText: 'Describe a photo',
              hintText: 'e.g. a red stop sign',
              suffixIcon: IconButton(
                key: const Key('image-search-search-text'),
                icon: const Icon(Icons.search),
                onPressed: c.busy ? null : () => c.searchText(_query.text),
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('image-search-search-photo'),
            onPressed: c.busy ? null : c.searchByPhoto,
            icon: const Icon(Icons.image_search),
            label: const Text('Search by photo…'),
          ),
          if (c.resultsFor case final query?) ...[
            const SizedBox(height: 16),
            Text(
              'Closest to $query'
              '${c.queryEmbed == null ? '' : ' (query embedded in ${_ms(c.queryEmbed!)})'}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (c.results.isEmpty)
              const Text('Nothing indexed yet.', style: _muted)
            else
              _ResultsGrid(controller: c, store: _deps.photos),
          ],
        ],
      ],
    );
  }
}

const _muted = TextStyle(color: Colors.white70, fontSize: 13);

String _ms(Duration d) => '${d.inMilliseconds} ms';

/// What runs, on what, and at what cost.
class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.controller});

  final ImageSearchController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final lines = switch (c.status) {
      ImageSearchStatus.loading => ['Loading the active embedder with images…'],
      ImageSearchStatus.failed => ['The image index is not open.'],
      ImageSearchStatus.ready => [
        'Backend: ${c.activeBackend?.name ?? 'unknown'} · '
            'loaded in ${_ms(c.loadTime!)} · ${c.dimension}-d · '
            '${[for (final m in c.modalities) m.name].join(' + ')}',
        'Profile: ${c.profileId}',
        if (c.medianEmbed case final median?)
          'Per image: last ${_ms(c.added.first.embed)}, median ${_ms(median)} '
              '(${c.added.length} this session)',
      ],
    };
    return Card(
      key: const Key('image-search-model'),
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'EmbeddingGemma 2 image search',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            for (final line in lines) Text(line, style: _muted),
            const SizedBox(height: 6),
            const Text(
              'Cost of images (440M): natively (CPU) the bundle writes a '
              '218 MB vision cache every time it loads, and the first image '
              'adds about 400-500 MB of RAM. Per image at 140 vision tokens: '
              'about 0.35 s on an Apple-silicon Mac, about 2 s on an Android '
              'flagship, more on mid-range phones; in a browser, on WebGPU, '
              'about 0.33 s on a Tesla T4. For text alone the 270M is '
              'lighter.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    this.onChooseModel,
    this.cardKey = const Key('image-search-error'),
  });

  final String message;
  final VoidCallback? onChooseModel;
  final Key cardKey;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: cardKey,
      color: Colors.red.shade900,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(message),
            if (onChooseModel case final choose?) ...[
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('image-search-choose-model'),
                onPressed: choose,
                child: const Text('Choose a model'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddedStrip extends StatelessWidget {
  const _AddedStrip({required this.controller, required this.store});

  final ImageSearchController controller;
  final PhotoStore store;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        key: const Key('image-search-added'),
        height: 92,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final photo in controller.added)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  children: [
                    _Thumbnail(
                      image: store.imageFor(photo.reference),
                      size: 64,
                    ),
                    Text(_ms(photo.embed), style: _muted),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResultsGrid extends StatelessWidget {
  const _ResultsGrid({required this.controller, required this.store});

  final ImageSearchController controller;
  final PhotoStore store;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (i, hit) in controller.results.indexed)
          SizedBox(
            key: Key('image-search-hit-$i'),
            width: 104,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Thumbnail(image: store.imageFor(hit.reference), size: 104),
                Text(
                  hit.score.toStringAsFixed(3),
                  key: Key('image-search-score-$i'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  hit.label,
                  key: Key('image-search-label-$i'),
                  style: _muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.image, required this.size});

  final ImageProvider image;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Decoded at the size it is shown (at least 2x), not the photo's: a
    // 12-megapixel original would otherwise be decoded whole for a 104 px tile.
    final px = (size * math.max(2.0, MediaQuery.devicePixelRatioOf(context)))
        .round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image(
        image: ResizeImage(
          image,
          width: px,
          height: px,
          policy: ResizeImagePolicy.fit,
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: size,
          color: Colors.white10,
          alignment: Alignment.center,
          child: const Icon(Icons.broken_image, color: Colors.white38),
        ),
      ),
    );
  }
}
