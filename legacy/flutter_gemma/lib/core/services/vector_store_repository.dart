import 'package:flutter_gemma/core/services/vector_store_filter.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart';

/// Abstract repository for vector store operations
///
/// Platform-specific implementations:
/// - Mobile: MobileVectorStoreRepository (via Pigeon → native SQLite)
/// - Web: WebVectorStoreRepository (SQLite WASM)
///
/// Design Principles:
/// - Repository pattern: Abstracts storage implementation
/// - Dependency Inversion: High-level code depends on abstraction
/// - Single Responsibility: Each method has one clear purpose
///
/// Thread Safety:
/// - Mobile: SQLite handles concurrency via ACID transactions
/// - Web: IndexedDB transactions provide isolation
abstract class VectorStoreRepository {
  /// Initialize vector store at given database path
  ///
  /// - Mobile: Creates/opens SQLite database file
  /// - Web: Opens IndexedDB database (path used as DB name)
  ///
  /// Must be called before any other operations.
  ///
  /// Throws [VectorStoreException] if initialization fails.
  Future<void> initialize(String databasePath);

  /// Add document with embedding to vector store
  ///
  /// **Auto-dimension detection**:
  /// - First document sets the dimension (e.g., 768D)
  /// - Subsequent documents must match that dimension
  ///
  /// **INSERT OR REPLACE behavior**:
  /// - If [id] exists, document is updated (replace)
  /// - If [id] is new, document is inserted
  ///
  /// Parameters:
  /// - [id]: Unique document identifier (PRIMARY KEY)
  /// - [content]: Document text content
  /// - [embedding]: Vector embedding (dimension auto-detected from first add)
  /// - [metadata]: Optional JSON string metadata
  ///
  /// Throws:
  /// - [StateError] if not initialized
  /// - [ArgumentError] if embedding dimension doesn't match existing documents
  /// Throws [VectorStoreException] if the store is initialized but holds
  /// on-disk data it could not read — an implementation must refuse rather
  /// than report an unreadable corpus as an empty one.
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  });

  /// Remove a document from the vector store by its ID.
  ///
  /// If the document does not exist, this is a no-op (does not throw).
  ///
  /// Throws [StateError] if not initialized.
  /// Throws [VectorStoreException] if the store is initialized but holds
  /// on-disk data it could not read — an implementation must refuse rather
  /// than report an unreadable corpus as an empty one.
  Future<void> removeDocument({required String id});

  /// Search for similar documents using cosine similarity
  ///
  /// Returns documents sorted by similarity (descending) where:
  /// - similarity >= [threshold]
  /// - Limited to top [topK] results
  ///
  /// **Cosine similarity formula**:
  /// ```
  /// similarity = (A · B) / (||A|| * ||B||)
  /// ```
  /// Where:
  /// - A · B = dot product
  /// - ||A|| = L2 norm of A
  ///
  /// Parameters:
  /// - [queryEmbedding]: Query vector (must match stored dimension)
  /// - [topK]: Maximum number of results to return
  /// - [threshold]: Minimum similarity score (0.0 to 1.0, default 0.0)
  /// - [filter]: Optional payload predicate. Honored by implementations that
  ///   support it (qdrant-edge, and sqlite-vec over declared [FilterSchema]
  ///   columns on both native and web). A condition on an undeclared/unsupported
  ///   field is treated as a no-op rather than an error, so passing a non-empty
  ///   filter to an implementation (or field) that ignores it returns the same
  ///   hits as `filter: null` — never throws.
  ///
  /// Returns:
  /// - List of [RetrievalResult] sorted by similarity (highest first)
  ///
  /// Throws:
  /// - [StateError] if not initialized
  /// - [ArgumentError] if query dimension doesn't match stored dimension
  /// Throws [VectorStoreException] if the store is initialized but holds
  /// on-disk data it could not read — an implementation must refuse rather
  /// than report an unreadable corpus as an empty one.
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  });

  /// Get vector store statistics
  ///
  /// Returns:
  /// - [documentCount]: Total number of documents
  /// - [vectorDimension]: Embedding dimension (0 if empty)
  ///
  /// Throws [StateError] if not initialized
  /// Throws [VectorStoreException] if the store is initialized but holds
  /// on-disk data it could not read — an implementation must refuse rather
  /// than report an unreadable corpus as an empty one.
  Future<VectorStoreStats> getStats();

  /// Clear all documents from vector store
  ///
  /// **Side effects**:
  /// - Deletes all rows from documents table
  /// - Resets dimension (next add will auto-detect again)
  ///
  /// Throws [StateError] if not initialized
  /// Throws [VectorStoreException] if the store is initialized but holds
  /// on-disk data it could not read — an implementation must refuse rather
  /// than report an unreadable corpus as an empty one.
  Future<void> clear();

  /// Persist everything written so far, without closing the store.
  ///
  /// Call it once after a bulk index. Writes are not necessarily on disk when
  /// [addDocument] returns: a store is free to hold them in memory and settle
  /// up later, and one of them does.
  ///
  /// **Per backend**:
  /// - Qdrant: **required.** Points added through the UniFFI shard live in its
  ///   in-RAM segment until the shard is flushed or unloaded. An index built
  ///   without this is gone when the process ends, and the corpus is embedded
  ///   again from scratch on the next launch.
  /// - SQLite, native: a genuine no-op. The connection is in autocommit and
  ///   never opens a transaction, so a statement that returned is on disk.
  /// - SQLite, web: **not** a no-op, and not a full guarantee either. The VFS
  ///   Flutter web gets is IndexedDB (OPFS needs a dedicated worker), whose
  ///   `xSync` does nothing and whose writes are asynchronous by design, so
  ///   this call is the drain. On `sqlite3` >= 3.4.0 that drain is partial: it
  ///   returns without awaiting a write batch already in flight (upstream
  ///   regression). The exposure is bounded — the VFS streams writes
  ///   continuously, so what is missed is the batch in flight, not the index.
  ///
  /// [close] persists too, and on web it is the *stronger* drain: it queues
  /// behind the running batch on every version. What close cannot cover is a
  /// process that never gets to close — an Android app the system kills in the
  /// background is the ordinary case, not the exceptional one — which is what
  /// this exists for. So the two are not interchangeable: prefer this one
  /// while the store stays open, and note that on qdrant a failure is reported
  /// by this call and swallowed by [close].
  ///
  /// Safe on a store that was never initialized, and safe to call repeatedly:
  /// implementations must not throw for either — there is nothing pending, so
  /// there is nothing to report.
  ///
  /// Otherwise this method's job is to be **loud**. An implementation that
  /// cannot persist — the write failed, or the store is on a backend with no
  /// durable storage behind it — must throw [VectorStoreException] rather than
  /// return normally. Silence is the failure this method exists to prevent:
  /// the caller asked for durability, and a quiet success tells them they have
  /// it while the index is still only in memory.
  ///
  /// The default body is a no-op, for backends that are already durable. Note
  /// that every implementation in this repository uses `implements` rather
  /// than `extends`, so none of them inherits it; it is here for the contract
  /// and for any future implementation that does extend.
  Future<void> flush() async {}

  /// Close vector store and release resources
  ///
  /// **Resource cleanup**:
  /// - Mobile: Closes SQLite database connection
  /// - Web: Closes IndexedDB connection
  ///
  /// Persists pending writes on the way out, so a [flush] immediately before
  /// this adds nothing. It is not a substitute for [flush], though: a store
  /// stays usable after flushing and does not after closing, and a failure
  /// here is logged rather than thrown — implementations treat close as
  /// cleanup the caller usually cannot act on, while [flush] reports.
  ///
  /// Idempotent: Safe to call multiple times
  Future<void> close();

  /// Check if vector store is initialized
  ///
  /// Returns true if [initialize] was called successfully
  bool get isInitialized;

  /// Legacy no-op kept for source compatibility.
  ///
  /// Vector search now runs inside the store's engine (qdrant-edge, or
  /// sqlite-vec/`vec0`), so there is no Dart-side HNSW to toggle. Implementations
  /// accept the get/set but ignore it. Scheduled for removal in 2.0.
  bool get enableHnsw;
  set enableHnsw(bool value);

  /// The filterable-metadata schema this store was configured with.
  ///
  /// Concrete (bodied) member with a no-op default, so an implementation that
  /// `extends` this class gets it for free. That does NOT spare an
  /// `implements`-er: `implements` inherits no bodies, so every store in this
  /// repository — all of which use `implements` — declares this itself, and
  /// adding a bodied member here is still a source-breaking change for an
  /// external `implements`-er.
  /// Stores that honor [Filter] (qdrant, sqlite/vec0) override [configure] to
  /// stash the schema and expose it here; everyone else keeps the empty default.
  FilterSchema get filterSchema => const FilterSchema();

  /// Declare which metadata fields this store should make filterable.
  ///
  /// Called **once at registration, before [initialize]** — the schema is
  /// threaded from `FlutterGemma.initialize(filterSchema:)` through the service
  /// registry into the store's constructor wiring, so the store can promote the
  /// declared fields to typed storage columns (vec0) or top-level payload keys
  /// (qdrant) the first time it creates its table / writes a document.
  ///
  /// Default is a no-op: a store that does not override this keeps ignoring
  /// filters, and the never-throws contract on [searchSimilar] still holds — an
  /// empty or undeclared-key [Filter] returns the same hits as `filter: null`,
  /// it never throws.
  void configure(FilterSchema schema) {}
}

/// Exception thrown by VectorStore operations
class VectorStoreException implements Exception {
  final String message;
  final Object? cause;

  const VectorStoreException(this.message, [this.cause]);

  @override
  String toString() =>
      'VectorStoreException: $message${cause != null ? '\nCause: $cause' : ''}';
}
