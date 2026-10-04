import 'dart:io';

import 'package:flutter_edge_ai_qdrant/src/atomic_directory_record.dart';
import 'package:path/path.dart' as p;

const _version = 1;
const _tempPrefix = '.flutter_edge_ai_rag.record.tmp.';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln('usage: profile_process_worker <path> <id> <dimension>');
    exitCode = 64;
    return;
  }

  try {
    final parent = p.join(arguments[0], 'qdrant_edge_v1');
    final dimension = int.parse(arguments[2]);
    final dimensionDirectory = p.join(
      parent,
      '.flutter_edge_ai_rag.embedding_dimension.v1',
    );
    await AtomicDirectoryRecord.publish(
      parentDirectory: parent,
      finalDirectory: dimensionDirectory,
      tempPrefix: _tempPrefix,
      json: {
        'schema': 'flutter_edge_ai_rag.embedding_dimension',
        'version': _version,
        'dimension': dimension,
      },
    );
    final persistedDimension = await AtomicDirectoryRecord.read(
      directoryPath: dimensionDirectory,
      schema: 'flutter_edge_ai_rag.embedding_dimension',
      version: _version,
      expectedKeys: const {'schema', 'version', 'dimension'},
    );
    if (persistedDimension?['dimension'] != dimension) {
      stdout.writeln('conflict:${arguments[1]}');
      exitCode = 2;
      return;
    }

    final profileDirectory = p.join(
      parent,
      '.flutter_edge_ai_rag.embedding_profile.v1',
    );
    await AtomicDirectoryRecord.publish(
      parentDirectory: parent,
      finalDirectory: profileDirectory,
      tempPrefix: _tempPrefix,
      json: {
        'schema': 'flutter_edge_ai_rag.embedding_profile',
        'version': _version,
        'id': arguments[1],
        'dimension': dimension,
      },
    );
    final persisted = await AtomicDirectoryRecord.read(
      directoryPath: profileDirectory,
      schema: 'flutter_edge_ai_rag.embedding_profile',
      version: _version,
      expectedKeys: const {'schema', 'version', 'id', 'dimension'},
    );
    if (persisted?['id'] == arguments[1]) {
      stdout.writeln('bound:${arguments[1]}');
    } else {
      stdout.writeln('conflict:${arguments[1]}');
      exitCode = 2;
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 70;
  }
}
