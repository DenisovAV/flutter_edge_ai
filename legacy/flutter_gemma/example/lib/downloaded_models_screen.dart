import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/chat_screen.dart';
import 'package:flutter_gemma_example/services/downloaded_model_deleter.dart';
import 'package:flutter_gemma_example/services/downloaded_model_loader.dart';
import 'package:flutter_gemma_example/utils/installed_model_lookup.dart';

class _DownloadedModelEntry {
  const _DownloadedModelEntry({
    required this.id,
    required this.displayName,
    required this.loadable,
    required this.isTokenizer,
  });

  final String id;
  final String displayName;
  final bool loadable;
  final bool isTokenizer;
}

class DownloadedModelsScreen extends StatefulWidget {
  const DownloadedModelsScreen({super.key});

  @override
  State<DownloadedModelsScreen> createState() => _DownloadedModelsScreenState();
}

class _DownloadedModelsScreenState extends State<DownloadedModelsScreen> {
  bool _loading = true;
  String? _error;
  List<_DownloadedModelEntry> _entries = [];
  Set<String> _loadedIds = {};
  String? _loadingId;
  String? _deletingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final installed = await FlutterGemma.listInstalledModels();
      final loadedIds = loadedModelIds();

      final entries = installed.where(isDownloadedModelArtifact).map((id) {
        final match = resolveCatalog(id);
        return _DownloadedModelEntry(
          id: id,
          displayName: match?.displayName ?? id,
          loadable: isLoadableArtifact(id),
          isTokenizer: match is EmbeddingMatch && match.isTokenizer,
        );
      }).toList();

      entries.sort((a, b) {
        final aLoaded = loadedIds.contains(a.id);
        final bLoaded = loadedIds.contains(b.id);
        if (aLoaded && !bLoaded) return -1;
        if (bLoaded && !aLoaded) return 1;
        return a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        );
      });

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loadedIds = loadedIds;
        _loadingId = null;
        _deletingId = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('Downloaded Models'),
        backgroundColor: const Color(0xFF0b2351),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Future<void> _confirmDelete(_DownloadedModelEntry entry) async {
    if (_loadingId != null || _deletingId != null) return;

    final deletesTokenizerToo =
        await DownloadedModelDeleter.willUninstallTokenizer(entry.id);
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          deletesTokenizerToo
              ? 'Remove ${entry.displayName} and its tokenizer from this device?'
              : 'Remove ${entry.displayName} from this device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _deletingId = entry.id;
    });

    try {
      await DownloadedModelDeleter.delete(entry.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted ${entry.displayName}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deletingId = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete model: $e')));
    }
  }

  Future<void> _copyPath(_DownloadedModelEntry entry) async {
    try {
      final path = await resolveInstalledModelPath(entry.id);
      await Clipboard.setData(ClipboardData(text: path));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied path for ${entry.displayName}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to copy path: $e')));
    }
  }

  Future<void> _loadEntry(_DownloadedModelEntry entry) async {
    if (_loadingId != null || !entry.loadable) return;
    setState(() {
      _loadingId = entry.id;
    });

    try {
      final match = resolveCatalog(entry.id);
      await DownloadedModelLoader.load(entry.id);
      if (!mounted) return;
      if (match case InferenceMatch(:final model)) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (context) => ChatScreen(model: model),
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Loaded ${entry.displayName}')));
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingId = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load model: $e')));
    }
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                'Failed to load models',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.download_outlined, size: 64, color: Colors.white54),
              SizedBox(height: 16),
              Text(
                'No downloaded models yet',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                'Download a model from Inference, Translation, or Embedding Models.',
                style: TextStyle(fontSize: 14, color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final isLoaded = _loadedIds.contains(entry.id);
        final isLoading = _loadingId == entry.id;
        final isDeleting = _deletingId == entry.id;
        final isBusy = _loadingId != null || _deletingId != null;
        final showSubtitle = entry.displayName != entry.id || entry.isTokenizer;
        final canDelete = !entry.isTokenizer;

        final trailingChildren = <Widget>[];
        if (isLoading || isDeleting) {
          trailingChildren.add(
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        } else if (isLoaded) {
          trailingChildren.add(
            const Chip(
              label: Text('Loaded'),
              backgroundColor: Color(0xFF1a5c3a),
              labelStyle: TextStyle(color: Colors.white, fontSize: 12),
            ),
          );
        }
        trailingChildren.add(
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy path',
            onPressed: () => _copyPath(entry),
          ),
        );
        if (!isLoading && !isDeleting && canDelete) {
          trailingChildren.add(
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: isBusy ? null : () => _confirmDelete(entry),
            ),
          );
        }

        return ListTile(
          enabled: entry.loadable && !isBusy,
          onTap: entry.loadable && !isBusy ? () => _loadEntry(entry) : null,
          title: Text(entry.displayName),
          subtitle: showSubtitle
              ? Text(
                  entry.isTokenizer
                      ? '${entry.id} • Tokenizer file (loaded with embedding model)'
                      : entry.id,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: trailingChildren,
          ),
        );
      },
    );
  }
}
