/*
 * any_shim.h: the C ABI of libany_shim, an in-process wrapper over
 * any-sync-sdk (spaces, objects, files, change feed, sync status) and an
 * any-store v2 local index (vectors + BM25), for flutter_edge_ai_any.
 *
 * This header is the contract. The Go implementation includes it, so cgo
 * refuses to compile an export whose signature drifts from it, and
 * check_exports.py refuses a library whose export table differs from the
 * ANY_SHIM_EXPORTS list in the same script.
 *
 * Conventions, every function:
 *   - Returns an any_shim_status: ANY_SHIM_OK (0) or an error code.
 *   - Writes results only through out-parameters, and only on ANY_SHIM_OK.
 *   - On an error, writes a malloc'd UTF-8 message to *out_error when
 *     out_error is not NULL. Messages are for people; branch on the code.
 *     Callers pre-initialise *out_error to NULL (it is left untouched on
 *     ANY_SHIM_OK).
 *   - Never lets a Go panic cross the boundary: a panic in the call is
 *     recovered and returned as ANY_SHIM_ERR_PANIC. A panic on a goroutine
 *     the SDK started itself is outside this guarantee.
 *   - Strings in are NUL-terminated UTF-8; NULL is read as "". Input
 *     pointers are never written through or kept after the call; they are
 *     not declared const because cgo cannot declare an export that way.
 *   - Strings out (*out_json, *out_id, *out_error, ...) are malloc'd and
 *     owned by the caller, who frees them with any_shim_free.
 *   - JSON out is always a complete document (object or array). The one
 *     exception: any_shim_index_get returns OK with *out_json = NULL for an
 *     absent row.
 *
 * Handles are opaque, non-zero uint64 values from a process-wide registry.
 * A handle that was never issued, or was closed, is ANY_SHIM_ERR_CLOSED; an
 * account handle passed where an index is expected (or the reverse) is
 * ANY_SHIM_ERR_INVALID_ARGUMENT. A handle is never dereferenced. Every function is safe to call from any thread.
 *
 * Network: an account needs a nodeconf YAML; there is no default network.
 * The production any-sync network is refused (ANY_SHIM_ERR_REFUSED) until
 * its terms for third-party apps are known. Global p2p (iroh relays) is
 * always off; LAN p2p (mDNS + QUIC) is on unless disabled.
 */
#ifndef ANY_SHIM_H_
#define ANY_SHIM_H_

#include <stdint.h>

/* Handles cross the boundary as uint64_t, and the finalizer-shaped
 * release functions take them as uintptr_t: 64-bit targets only. */
#ifdef __cplusplus
static_assert(sizeof(uintptr_t) == 8, "any_shim needs a 64-bit target");
#else
_Static_assert(sizeof(uintptr_t) == 8, "any_shim needs a 64-bit target");
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any incompatible change to this header. The Dart side refuses
 * a library whose any_shim_abi_version() differs from the value it was
 * written against. */
#define ANY_SHIM_ABI_VERSION 2

typedef int32_t any_shim_status;

#define ANY_SHIM_OK 0
/* An argument is malformed: bad JSON, a dimension mismatch, an empty id. */
#define ANY_SHIM_ERR_INVALID_ARGUMENT 1
/* The space, object or file is not known on this device (yet). */
#define ANY_SHIM_ERR_NOT_FOUND 2
/* The object existed and was deleted, here or on a peer. */
#define ANY_SHIM_ERR_DELETED 3
/* The handle is unknown or was closed, or the account is closing. */
#define ANY_SHIM_ERR_CLOSED 4
/* A deadline passed (timeout_ms), e.g. a file no reachable peer holds. */
#define ANY_SHIM_ERR_TIMEOUT 5
/* The request is valid but not allowed here (production network, an
 * index mode that is not supported). */
#define ANY_SHIM_ERR_REFUSED 6
/* Anything the SDK or any-store reported that has no code above. */
#define ANY_SHIM_ERR_INTERNAL 7
/* A Go panic inside the call, recovered. The handle may be unusable. */
#define ANY_SHIM_ERR_PANIC 8
/* A compare-and-set in index_apply missed, or index_bind was asked for
 * another configuration than the index has. Nothing was applied. */
#define ANY_SHIM_ERR_CONFLICT 9
/* The local index is damaged (or was written by an unknown format). */
#define ANY_SHIM_ERR_CORRUPT 10
/* The local index was written with another key, or with none. */
#define ANY_SHIM_ERR_KEY_MISMATCH 11
/* Retryable: a lock held by another process, a directory still held by a
 * previous owner (a hot restart) or still closing. */
#define ANY_SHIM_ERR_BUSY 12
/* An op (any_shim_op_wait) has not finished yet; or a space is still
 * loading (start any_shim_space_resolve_start and wait for it). */
#define ANY_SHIM_ERR_PENDING 13
/* Retryable: the local index needs a key and none was given. */
#define ANY_SHIM_ERR_KEY_MISSING 14
/* Retryable: the file system refused (permission, disk full). */
#define ANY_SHIM_ERR_IO 15

/* No exported call blocks for long. A call that may wait on the network or
 * on a close is split into *_start, which returns an op handle at once,
 * and any_shim_op_wait, which waits at most ~250 ms per call. Everything
 * else returns within a local database operation; the one exception is
 * any_shim_file_attach (proportional to the file). */

/* ---------------------------------------------------------------- misc */

uint32_t any_shim_abi_version(void);

/* Frees a string this library returned. NULL is a no-op. */
void any_shim_free(void *ptr);

/* {"abi":2,"shim":"…","go":"go1.x","modules":{"github.com/…":"v…"}} */
any_shim_status any_shim_version(char **out_json, char **out_error);

/* A new 12-word BIP-39 mnemonic. Persisting it is the caller's job. */
any_shim_status any_shim_new_mnemonic(char **out_mnemonic, char **out_error);

/* A new device key, hex. One per install. Persisting it is the caller's
 * job (store it "this device only": a restored key is a second writer). */
any_shim_status any_shim_new_device_key(char **out_hex, char **out_error);

/* ------------------------------------------------------------------ ops */

/* Waits up to wait_ms (clamped to 0..250) for the op. While it runs:
 * ANY_SHIM_ERR_PENDING. When it has finished: its own status and, on OK,
 * its result in *out_json; the op handle is then released (a later call
 * is ANY_SHIM_ERR_CLOSED). */
any_shim_status any_shim_op_wait(uint64_t op, int32_t wait_ms,
                                 char **out_json, char **out_error);

/* Asks the op to stop and releases the handle; its result is discarded.
 * Never blocks. A space load started by space_resolve_start is NOT
 * cancelled (only closing the account cancels it). */
any_shim_status any_shim_op_cancel(uint64_t op, char **out_error);

/* ------------------------------------------------------------- account */

/* opts_json:
 *   dataDir          string, required: the SDK's storage directory
 *   indexDir         string, required: the account's local index root;
 *                    two open accounts may not share one
 *   ownerToken       string, required: random per isolate group. A
 *                    directory held by another token (a previous hot
 *                    restart generation) or still closing is
 *                    ANY_SHIM_ERR_BUSY at once; the caller retries. Held
 *                    by the same token (already open in this isolate
 *                    group): ANY_SHIM_ERR_REFUSED. A directory whose
 *                    previous instance's SDK close (or open) panicked:
 *                    ANY_SHIM_ERR_REFUSED "the previous instance failed
 *                    to close; restart the app (cause: …)", for the life
 *                    of the process (never a second writer). A close that
 *                    returned an error still released the directory.
 *                    An account a finished open op holds for these
 *                    directories under another token, which nobody has
 *                    op_waited on since it finished more than 5 s ago (a
 *                    dead hot-restart generation), is closed by this
 *                    start (which answers ANY_SHIM_ERR_BUSY until the
 *                    close is done).
 *   mnemonic         string, required
 *   accountIndex     uint, optional
 *   deviceKeyHex     string, required
 *   nodeConfYaml     string, required; the production network is refused
 *   p2p              {"enabled","localDiscovery","serviceName","port"}
 *   logLevel         "debug"|"info"|"warn"|"error" (default "error")
 * The start call validates the options, claims both directories and takes
 * flock/LockFileEx on <dataDir>/.shimlock (another process holding it is
 * ANY_SHIM_ERR_BUSY), all synchronously: BUSY and REFUSED come back from
 * the start call itself. The SDK opens in the op. Op result:
 * {"account":<uint64 handle, as a JSON number>}. A failed or cancelled op
 * releases the claims and the lock (an account opened by a cancelled op
 * is closed again). */
any_shim_status any_shim_account_open_start(char *opts_json,
                                            uint64_t *out_op,
                                            char **out_error);

/* Cancels every call and space load in flight; never blocks; any thread.
 * Calls blocked on the network return at once (ANY_SHIM_ERR_CLOSED).
 * Terminal: afterwards every call is ANY_SHIM_ERR_CLOSED; only
 * account_close_start and account_release are useful. */
any_shim_status any_shim_account_cancel(uint64_t account, char **out_error);

/* Starts the close (cancel, end watches, SDK close, unlock). The op's
 * result is {}. The handle is invalid at once. wait_loads_ms > 0: inside
 * the op (and inside the iOS background task), first waits up to that
 * long for space loads in flight to finish, then cancels and closes; a
 * suspend passes 25000, a close 0 (cancel at once). Clamped to 0..25000;
 * on iOS also to the background time left minus 5 s; op_cancel of the
 * close op cuts the wait short (the close still runs). */
any_shim_status any_shim_account_close_start(uint64_t account,
                                             int32_t wait_loads_ms,
                                             uint64_t *out_op,
                                             char **out_error);

/* Finalizer-shaped: void(void*) compatible. Takes the handle out of the
 * registry atomically (a stale or already closed handle is a no-op),
 * marks the directory closing at once and closes on a goroutine. Never
 * blocks, never panics across the boundary. */
void any_shim_account_release(uintptr_t account);

/* {"accountId","peerId","techSpaceId","p2p":{…}} */
any_shim_status any_shim_account_info(uint64_t account, char **out_json,
                                      char **out_error);

any_shim_status any_shim_set_local_discovery(uint64_t account,
                                             int32_t enabled,
                                             char **out_error);

/* -------------------------------------------------------------- spaces */

/* {"id"}. Recorded in the account state as created on this device. If
 * that save fails after the space exists, still OK, with the id and
 * "stateSaveError":string (never create the space a second time). */
any_shim_status any_shim_space_create(uint64_t account, char *name,
                                      char **out_json, char **out_error);

/* The local list: {"spaces":[{"id","name","status"}]} */
any_shim_status any_shim_space_list(uint64_t account, char **out_json,
                                    char **out_error);

/* Asks reachable peers for the space list, then lists. timeout_ms > 0.
 * Op result: {"spaces":[…],"syncError":null|string,"timedOut":bool} */
any_shim_status any_shim_space_list_sync_start(uint64_t account,
                                               int32_t timeout_ms,
                                               uint64_t *out_op,
                                               char **out_error);

/* Makes the space available. The first call per space starts one detached
 * load (single-flight; only the account's close cancels it; a failed load
 * frees the slot). Op result: {"spaceId"}. Unknown to the account:
 * ANY_SHIM_ERR_NOT_FOUND. Other calls that take a space id return
 * ANY_SHIM_ERR_PENDING while the load runs. */
any_shim_status any_shim_space_resolve_start(uint64_t account,
                                             char *space_id,
                                             uint64_t *out_op,
                                             char **out_error);

/* {"spaceId","state","loading","p2p","localPeers","networkPeers",
 *  "globalPeers","synced","total","lastSyncedAt":null|RFC3339,
 *  "everPeerSynced":bool,"createdHere":bool}.
 * everPeerSynced is persisted in the account state: set the first time a
 * peer sync of the space completed on this device. ANY_SHIM_ERR_NOT_FOUND
 * for an id the account does not know. Also "stateSaveError":null|string:
 * the last save of the account state failed (cleared by a later save that
 * succeeds), so the persisted flags may be behind the reported ones. */
any_shim_status any_shim_space_status(uint64_t account, char *space_id,
                                      char **out_json, char **out_error);

/* Pushes heads to reachable peers and waits for an answer, up to
 * timeout_ms (> 0). Op result: {"reachedPeer":bool,"timedOut":bool,
 * "error":null|string}; a network failure is a result, not a status. */
any_shim_status any_shim_space_sync_heads_start(uint64_t account,
                                                char *space_id,
                                                int32_t timeout_ms,
                                                uint64_t *out_op,
                                                char **out_error);

/* --------------------------------------------------------- rag bundles */

/* The two RAG bundles (flutter_edge_ai.rag.location/v1 and
 * flutter_edge_ai.rag.document/v1), declared here and nowhere else.
 * ensure != 0 installs them (Bundles().Ensure, DerivedRoot); a winner that
 * is not the derived root is ANY_SHIM_ERR_REFUSED; a member without write
 * permission is ANY_SHIM_ERR_REFUSED with "read-only". ensure == 0 only
 * reads (ANY_SHIM_ERR_NOT_FOUND while the definitions have not synced).
 * {"location":{"rootId","properties":{xkey:id},"tombstones":collection},
 *  "document":{"rootId","properties":{xkey:id}}} */
any_shim_status any_shim_rag_bundles(uint64_t account, char *space_id,
                                     int32_t ensure, char **out_json,
                                     char **out_error);

/* ------------------------------------------------------------- objects */

/* target_json: {"id"} | {"create":{"type"}} | {"derive":{"seed","type"}}
 * ops_json: [{"xkey","value"} | {"xkey","leaf","value"}]: $set of a
 * declared property, or of one leaf of an object-kind property (leaf:
 * [0-9a-z-]+). An xkey the type does not declare: ANY_SHIM_ERR_NOT_FOUND
 * while the type's definitions are not synced, else
 * ANY_SHIM_ERR_INVALID_ARGUMENT. Any SDK error or op rejection is non-OK:
 * a deleted object or record is ANY_SHIM_ERR_DELETED, anything else
 * ANY_SHIM_ERR_REFUSED with the reasons; a create whose own ops failed
 * deletes the object again first. A create is one change.
 * out_json: {"id","created"}; for derive, created = the object carried no
 * value of its type before this call. */
any_shim_status any_shim_object_patch(uint64_t account, char *space_id,
                                      char *target_json, char *ops_json,
                                      char **out_json, char **out_error);

/* The editor body, one paragraph per non-empty line (display only). */
any_shim_status any_shim_object_set_body(uint64_t account, char *space_id,
                                         char *object_id, char *text,
                                         char **out_error);

/* request_json: {"ids":[…]} | {"type","after","limit"}, plus
 * "xkeys":[…], the properties to return (by xkey).
 * {"anchor":{"generation","maxApplySeq"},
 *  "items":[{"id","typeId","state":"ok"|"missing"|"deleted",
 *            "props":{xkey:value}}],
 *  "next":null|id}
 * limit: default 100, at most 1000. "missing" also covers an object whose
 * tree is here but whose typed row has not arrived (typeId null). An xkey
 * the item's type does not declare reads null.
 * The anchor is read before the page (generation, seq, generation,
 * retried until stable). Type pages are ordered by object id. */
any_shim_status any_shim_object_read(uint64_t account, char *space_id,
                                     char *request_json, char **out_json,
                                     char **out_error);

/* The id object_patch {"derive":{"seed","type"}} would produce, computed
 * without a write (a reader may call it; the space need not be loaded).
 * The type does not enter the id. {"id"} */
any_shim_status any_shim_object_derive_id(uint64_t account, char *space_id,
                                          char *seed, char **out_json,
                                          char **out_error);

/* Deletes an object for every device. A derived object is
 * ANY_SHIM_ERR_REFUSED; an already deleted one is OK. */
any_shim_status any_shim_object_delete(uint64_t account, char *space_id,
                                       char *object_id,
                                       char **out_error);

/* {"state":"synced"|"syncing"|"offline"|"unknown"|…}: whether a peer has
 * acknowledged the object's heads. */
any_shim_status any_shim_object_sync_state(uint64_t account,
                                           char *space_id, char *object_id,
                                           char **out_json,
                                           char **out_error);

/* Records of a records dataset on an object (the tombstones).
 * records_json: [{"id","set":{field:value},"addToSet":{field:value}}],
 * upserted, in one change. Rejections are non-OK as in object_patch. */
any_shim_status any_shim_records_modify(uint64_t account, char *space_id,
                                        char *object_id, char *collection,
                                        char *records_json,
                                        char **out_error);

/* Records ordered by id after `after` (NULL or "" = from the start), with
 * _applySeq > since_apply_seq. limit <= 0: 500.
 * {"records":[{…, "_applySeq"}],"next":null|id}; the SDK's other "_"
 * fields are left out. */
any_shim_status any_shim_records_read(uint64_t account, char *space_id,
                                      char *object_id, char *collection,
                                      char *after, uint64_t since_apply_seq,
                                      int32_t limit, char **out_json,
                                      char **out_error);

/* --------------------------------------------------- change feed, events */

/* {"generation","maxApplySeq","changes":[{"objectId","applySeq","deleted"}]} */
any_shim_status any_shim_changes_since(uint64_t account, char *space_id,
                                       uint64_t since, int32_t limit,
                                       char **out_json, char **out_error);

any_shim_status any_shim_watch_changes(uint64_t account, char *space_id,
                                       int64_t *out_watch, char **out_error);

any_shim_status any_shim_watch_sync_status(uint64_t account,
                                           int64_t *out_watch,
                                           char **out_error);

any_shim_status any_shim_unwatch(uint64_t account, int64_t watch,
                                 char **out_error);

/* As in ABI 1, but timeout_ms is clamped to 0..250. Events:
 *   {"kind":"change","watch","spaceId","objectId","applySeq","deleted"}
 *   {"kind":"syncStatus","watch","spaceId","state","p2p","localPeers",
 *    "networkPeers","globalPeers","total","lastSyncedAt"}
 *   {"kind":"overflow","dropped"} */
any_shim_status any_shim_events_poll(uint64_t account, int32_t max_events,
                                     int32_t timeout_ms, char **out_json,
                                     char **out_error);

/* --------------------------------------------------------------- files */

/* An exception to the ~250 ms rule: copies the file into the space, in
 * time proportional to its size. The RAG provider does not call it. */
any_shim_status any_shim_file_attach(uint64_t account, char *space_id,
                                     char *object_id, char *path,
                                     char *name, char **out_json,
                                     char **out_error);
any_shim_status any_shim_file_list(uint64_t account, char *space_id,
                                   char *object_id, char **out_json,
                                   char **out_error);
any_shim_status any_shim_file_status(uint64_t account, char *space_id,
                                     char *file_id, char **out_json,
                                     char **out_error);
/* Op result: {"bytes"}. Written to a sibling temp file, then renamed. */
any_shim_status any_shim_file_read_start(uint64_t account, char *space_id,
                                         char *file_id, char *out_path,
                                         int32_t timeout_ms,
                                         uint64_t *out_op,
                                         char **out_error);

/* --------------------------------------------- local index (never synced) */

/* opts_json: {"path" (the database file), "keyHex" (64 hex chars, or
 * absent/empty for no encryption), "ownerToken"}.
 * Keycheck sidecar <path>.keycheck, written (tmp, fsync, rename, fsync of
 * the directory) before the database is created:
 *   no sidecar, no file          create both
 *   sidecar, no file             rewrite the sidecar, create the file
 *   plain sidecar + key, or
 *   another key                  ANY_SHIM_ERR_KEY_MISMATCH
 *   keyed sidecar, no key        ANY_SHIM_ERR_KEY_MISSING
 *   fileId inside != sidecar's   ANY_SHIM_ERR_KEY_MISMATCH
 *   decrypt failure after a
 *   matching sidecar             ANY_SHIM_ERR_CORRUPT
 *   no sidecar, file present     ANY_SHIM_ERR_CORRUPT
 *   EACCES/EPERM/ENOSPC          ANY_SHIM_ERR_IO
 * Takes flock/LockFileEx on <path>.shimlock; held by another process:
 * ANY_SHIM_ERR_BUSY. The same path open under another ownerToken, or
 * closing: ANY_SHIM_ERR_BUSY; under the same token: ANY_SHIM_ERR_REFUSED;
 * after a close whose database close panicked: ANY_SHIM_ERR_REFUSED "the
 * previous instance failed to close" with its cause (as for accounts; a
 * close that returned an error still released the path).
 * Index calls never wait behind a bind or a generation swap: while one
 * holds the index exclusively, the other index calls (apply, get, scan,
 * count, count_vectors, knn, text, flush, gc, info, bind_start) return
 * ANY_SHIM_ERR_PENDING ("index busy") at once; retry in slices. An apply
 * with shadowBegin or shadowSwap itself waits up to 250 ms for the
 * exclusive lock, then returns ANY_SHIM_ERR_PENDING.
 * Orphan generation collections (an unswapped shadow included) are only
 * recorded; any_shim_index_gc drops them. */
any_shim_status any_shim_index_open(char *opts_json, uint64_t *out_index,
                                    char **out_error);

/* Starts the close; the handle is invalid at once. Op result: {}. */
any_shim_status any_shim_index_close_start(uint64_t index, uint64_t *out_op,
                                           char **out_error);

/* Finalizer-shaped, as any_shim_account_release. */
void any_shim_index_release(uintptr_t index);

/* bind_json: {"dim","metric":"cosine"|"l2"|"dot",
 *             "fields":[{"key","type":"string"|"number"|"bool"}],
 *             "textSearch":bool}
 * Idempotent; fields and textSearch may only grow (a new field gets its
 * range index); another dim or metric, or a field key with another type,
 * is ANY_SHIM_ERR_CONFLICT (returned by the start call; also by the op
 * when a concurrent bind got in first). The config lives
 * in meta and survives swaps. A bind that adds an index builds it over
 * every existing row, so it runs in an op. Op result:
 * {"dim","metric","fields","textSearch"} */
any_shim_status any_shim_index_bind_start(uint64_t index, char *bind_json,
                                          uint64_t *out_op,
                                          char **out_error);

/* {} before any bind; otherwise the same object index_bind returns,
 * plus "fileId". */
any_shim_status any_shim_index_info(uint64_t index, char **out_json,
                                    char **out_error);

/* One write transaction. ops_json:
 *  {"cas":[{"key","expect":null|string}],     state keys, checked first
 *   "ops":[
 *     {"op":"upsert","coll":"docs"|"shadow","id","text","meta","f":{…},
 *      "vector":null|{"offset":int,"dim":int}},
 *     {"op":"delete","coll":"docs"|"shadow","id"},
 *     {"op":"clearDocs","coll":"docs"|"shadow"},
 *     {"op":"stateSet","coll":"state"|"shadowState","key","value":null|string},
 *     {"op":"shadowBegin"},                    drops any shadow, starts a
 *                                              new generation
 *     {"op":"shadowSwap"}]}                    makes the shadow active:
 *                                              flips meta.active only; the
 *                                              old generation becomes an
 *                                              orphan for index_gc
 * vectors: vector_floats floats; every vector slot satisfies offset >= 0,
 * offset + dim <= vector_floats, dim == the bound dim; the slots tile the
 * buffer in order; no NaN or Inf. Everything is validated before the
 * transaction: a bad op is ANY_SHIM_ERR_INVALID_ARGUMENT, a vector before
 * index_bind ANY_SHIM_ERR_REFUSED, a CAS miss ANY_SHIM_ERR_CONFLICT; in
 * each case nothing is applied. {"applied":n} */
any_shim_status any_shim_index_apply(uint64_t index, char *ops_json,
                                     float *vectors, int64_t vector_floats,
                                     char **out_json, char **out_error);

/* Drops orphan generations, a bounded amount of work per call (about
 * budget_ms, clamped to 0..250). {"done":bool}: true once no orphan is
 * left. Call after a swap and after open until done. */
any_shim_status any_shim_index_gc(uint64_t index, int32_t budget_ms,
                                  char **out_json, char **out_error);

/* A row of docs (or shadow), or a state value. *out_json = NULL when
 * absent. coll: "docs"|"shadow"|"state"|"shadowState" (a shadow coll
 * without a shadow: ANY_SHIM_ERR_INVALID_ARGUMENT).
 * Row: {"id","text","meta","f":{…},"vector":null|[floats]};
 * state entry: {"key","value"}. */
any_shim_status any_shim_index_get(uint64_t index, char *coll, char *id,
                                   char **out_json, char **out_error);

/* Rows or state entries by id/key after `after`, at most limit (<= 0:
 * 500), keys starting with prefix (NULL = all). Rows come without their
 * vector: {"id","text","meta","f","hasVector"}; state entries as in
 * index_get. {"items":[…],"next":null|string} */
any_shim_status any_shim_index_scan(uint64_t index, char *coll,
                                    char *prefix, char *after,
                                    int32_t limit, char **out_json,
                                    char **out_error);

/* Rows in docs, and rows with a vector. */
any_shim_status any_shim_index_count(uint64_t index, int64_t *out_count,
                                     char **out_error);
any_shim_status any_shim_index_count_vectors(uint64_t index,
                                             int64_t *out_count,
                                             char **out_error);

/* Exact k nearest rows with a vector, under an optional Mongo-style filter
 * on the stored fields (paths f.<key>, combined with $and/$or/$nor).
 * k: 1..10000. Before index_bind: ANY_SHIM_ERR_REFUSED.
 * {"results":[{"id","text","meta","distance"}]} */
any_shim_status any_shim_index_knn(uint64_t index, float *query,
                                   int32_t dim, int32_t k,
                                   char *filter_json, char **out_json,
                                   char **out_error);

/* BM25 over text, sorted by score descending then id, before the limit.
 * query is passed to any-store's $search as given (the caller quotes).
 * Without textSearch bound: ANY_SHIM_ERR_REFUSED.
 * {"results":[{"id","text","meta","score"}]} */
any_shim_status any_shim_index_text(uint64_t index, char *query,
                                    int32_t k, char *filter_json,
                                    char **out_json, char **out_error);

/* Waits up to wait_ms (0..250) for pending full-text work to commit.
 * Checkpoints now; wait_ms bounds the wait for the writer (0: one try of
 * at most 250 ms). Not done in time: ANY_SHIM_ERR_TIMEOUT (retryable). */
any_shim_status any_shim_index_flush(uint64_t index, int32_t wait_ms,
                                     char **out_error);

#ifdef __cplusplus
}
#endif

#endif /* ANY_SHIM_H_ */
