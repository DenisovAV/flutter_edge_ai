import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';

/// Registry for managing source handlers
///
/// Features:
/// - Finds appropriate handler for any ModelSource
/// - Strategy pattern - delegates to specific handlers
/// - First-match wins (order matters when registering handlers)
/// - Type-safe with sealed ModelSource classes
class SourceHandlerRegistry {
  final List<SourceHandler> handlers;

  SourceHandlerRegistry({required this.handlers});

  /// Finds the appropriate handler for the given source
  ///
  /// Returns the first handler that supports the source type.
  /// Order matters - handlers are checked in registration order.
  ///
  /// Throws [UnsupportedError] if no handler supports the source.
  SourceHandler? getHandler(ModelSource source) {
    for (final handler in handlers) {
      if (handler.supports(source)) {
        return handler;
      }
    }
    throw UnsupportedError(
      'No handler found for source type: ${source.runtimeType}',
    );
  }
}
