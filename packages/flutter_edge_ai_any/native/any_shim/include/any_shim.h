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
 *   - Never lets a Go panic cross the boundary: a panic in the call is
 *     recovered and returned as ANY_SHIM_ERR_PANIC. A panic on a goroutine
 *     the SDK started itself is outside this guarantee.
 *   - Strings in are NUL-terminated UTF-8; NULL is read as "". Input
 *     pointers are never written through or kept after the call; they are
 *     not declared const because cgo cannot declare an export that way.
 *   - Strings out (*out_json, *out_id, *out_error, ...) are malloc'd and
 *     owned by the caller, who frees them with any_shim_free.
 *   - JSON out is always a complete document (object or array).
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

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any incompatible change to this header. The Dart side refuses
 * a library whose any_shim_abi_version() differs from the value it was
 * written against. */
#define ANY_SHIM_ABI_VERSION 1

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

/* ---------------------------------------------------------------- misc */

uint32_t any_shim_abi_version(void);

/* Frees a string this library returned. NULL is a no-op. */
void any_shim_free(void *ptr);

/* {"abi":1,"shim":"…","go":"go1.x","modules":{"github.com/…":"v…"}} */
any_shim_status any_shim_version(char **out_json, char **out_error);

/* A new 12-word BIP-39 mnemonic. Persisting it is the caller's job. */
any_shim_status any_shim_new_mnemonic(char **out_mnemonic, char **out_error);

/* A new device key, hex. One per install: peers tell devices of one
 * account apart by it. Persisting it is the caller's job. */
any_shim_status any_shim_new_device_key(char **out_hex, char **out_error);

/* ------------------------------------------------------------- account */

/* opts_json:
 *   dataDir        string, required: the SDK's storage directory
 *   mnemonic       string, required
 *   accountIndex   uint, optional (default: the SDK's, 1 = `any`'s)
 *   deviceKeyHex   string, required (any_shim_new_device_key)
 *   nodeConfYaml   string, required; the production network is refused
 *   p2p            {"enabled":bool,"localDiscovery":bool,
 *                   "serviceName":string,"port":int}, all optional
 *   logLevel       "debug"|"info"|"warn"|"error" (default "error"),
 *                  process-wide, applied by the first open only
 */
any_shim_status any_shim_account_open(char *opts_json,
                                      uint64_t *out_account,
                                      char **out_error);

/* Ends every watch (pollers get ANY_SHIM_ERR_CLOSED), cancels calls in
 * flight and closes the SDK. The handle is invalid afterwards, even when
 * an error is returned. */
any_shim_status any_shim_account_close(uint64_t account, char **out_error);

/* {"accountId","peerId","techSpaceId",
 *  "p2p":{"enabled","listening","port","state","localDiscovery",
 *         "peers":[{"peerId","connected","spaceIds"}]}} */
any_shim_status any_shim_account_info(uint64_t account, char **out_json,
                                      char **out_error);

/* Starts or stops mDNS announce/browse; the QUIC listener stays up. */
any_shim_status any_shim_set_local_discovery(uint64_t account,
                                             int32_t enabled,
                                             char **out_error);

/* -------------------------------------------------------------- spaces */

/* {"id"} */
any_shim_status any_shim_space_create(uint64_t account, char *name,
                                      char **out_json, char **out_error);

/* {"spaces":[{"id","name","status"}],"syncError":null|string}.
 * sync != 0 first asks reachable peers for the account's space list; a
 * failure is reported in syncError and the local list is still returned.
 * A null syncError means the SDK reported no error, not that a peer
 * answered (the SDK does not surface per-peer failures). */
any_shim_status any_shim_space_list(uint64_t account, int32_t sync,
                                    char **out_json, char **out_error);

/* {"spaceId","state","p2p","localPeers","networkPeers","globalPeers",
 *  "synced","total"}. ANY_SHIM_ERR_NOT_FOUND for an id the account does
 * not know (the SDK itself answers "unknown" for any string). */
any_shim_status any_shim_space_status(uint64_t account, char *space_id,
                                      char **out_json, char **out_error);

/* Pushes this device's heads to every reachable peer of the space. */
any_shim_status any_shim_space_sync_heads(uint64_t account,
                                          char *space_id,
                                          char **out_error);

/* ------------------------------------------------------------- objects */

/* Writes a document object (type "RAG Document", created in the space on
 * first use). doc_json:
 *   id      existing object id to update, or
 *   seed    a caller key; the object id is derived from it, the same on
 *           every device (Objects().Derive), so a re-put is idempotent;
 *           such an object can never be deleted (any_shim_object_delete);
 *           with neither, a fresh object is created
 *   name    string -> any.name
 *   text    string -> the body, one editor paragraph per non-empty line,
 *           replacing the previous body
 *   source  string, optional
 *   meta    JSON object, optional, stored as its JSON text
 * out_json: {"id","created"}. A new object whose later writes fail is
 * deleted again before the error is returned. A document type found
 * without its properties (still syncing, or its creator stopped halfway) is
 * completed rather than duplicated. */
any_shim_status any_shim_object_put(uint64_t account, char *space_id,
                                    char *doc_json, char **out_json,
                                    char **out_error);

/* {"id","type","isDocument","name","text","source","meta","row"};
 * meta is the stored JSON text (null when absent), row the raw object row.
 * ANY_SHIM_ERR_NOT_FOUND / ANY_SHIM_ERR_DELETED when it is not here. */
any_shim_status any_shim_object_get(uint64_t account, char *space_id,
                                    char *object_id, char **out_json,
                                    char **out_error);

/* Deletes an object for every device (final: the id is never reused).
 * An object written with a seed is ANY_SHIM_ERR_REFUSED: any-sync never
 * deletes a derived object, whose id anyone can derive again. Clear it
 * with any_shim_object_put instead, or write objects that must be
 * deletable without a seed. */
any_shim_status any_shim_object_delete(uint64_t account, char *space_id,
                                       char *object_id,
                                       char **out_error);

/* Object rows matching a Mongo-style filter (JSON; NULL, "" or "{}" = all).
 * limit <= 0 = no limit. [row, ...] */
any_shim_status any_shim_object_query(uint64_t account, char *space_id,
                                      char *filter_json, int32_t limit,
                                      char **out_json, char **out_error);

/* --------------------------------------------------------------- files */

/* Attaches the file at path to the object. name may be NULL (the base
 * name is used). out_json: the SDK's FileInfo. */
any_shim_status any_shim_file_attach(uint64_t account, char *space_id,
                                     char *object_id, char *path,
                                     char *name, char **out_json,
                                     char **out_error);

/* [FileInfo]; object_id NULL or "" = every file of the space. */
any_shim_status any_shim_file_list(uint64_t account, char *space_id,
                                   char *object_id, char **out_json,
                                   char **out_error);

/* The SDK's FileStatus (local presence, upload/download state). */
any_shim_status any_shim_file_status(uint64_t account, char *space_id,
                                     char *file_id, char **out_json,
                                     char **out_error);

/* Copies the file's original bytes to out_path (written to a sibling temp
 * file, then renamed), fetching from a peer if needed. timeout_ms <= 0 =
 * no deadline; otherwise ANY_SHIM_ERR_TIMEOUT when it passes. A read
 * shorter than the file's recorded size is an error, never a file. */
any_shim_status any_shim_file_read(uint64_t account, char *space_id,
                                   char *file_id, char *out_path,
                                   int32_t timeout_ms, int64_t *out_bytes,
                                   char **out_error);

/* --------------------------------------------------- change feed, events */

/* The durable feed: changes with applySeq > since, oldest first.
 * {"generation","maxApplySeq",
 *  "changes":[{"objectId","applySeq","deleted"}]}
 * The consumer's cursor is void, and it reindexes from 0, when the
 * generation differs from the one it stored, or when its cursor is above
 * maxApplySeq (the SDK's data was restored from an older copy). limit <= 0 = the SDK's default. */
any_shim_status any_shim_changes_since(uint64_t account, char *space_id,
                                       uint64_t since, int32_t limit,
                                       char **out_json, char **out_error);

/* Subscribes to a space's change feed; events go to the account's queue
 * (any_shim_events_poll). Best effort: an event that finds the queue full
 * is dropped, and one {"kind":"overflow"} marker per lost stretch says so;
 * events queued after the marker may still arrive. The consumer replays
 * from its cursor. */
any_shim_status any_shim_watch_changes(uint64_t account, char *space_id,
                                       int64_t *out_watch, char **out_error);

/* Subscribes to sync status changes of every space. */
any_shim_status any_shim_watch_sync_status(uint64_t account,
                                           int64_t *out_watch,
                                           char **out_error);

/* Ends a watch. An unknown id is ANY_SHIM_ERR_NOT_FOUND. */
any_shim_status any_shim_unwatch(uint64_t account, int64_t watch,
                                 char **out_error);

/* Blocks until at least one event is queued or timeout_ms passes
 * (<= 0: return at once), then returns up to max_events (<= 0: 256) as a
 * JSON array, possibly empty. Events:
 *   {"kind":"change","watch","spaceId","objectId","applySeq","deleted"}
 *   {"kind":"syncStatus","watch","spaceId","state","p2p","localPeers",
 *    "networkPeers","globalPeers","total"}
 *   {"kind":"overflow","dropped"}: events were dropped, from any watch.
 *    Replay changes from the stored cursor (any_shim_changes_since) and
 *    re-read sync status (any_shim_space_status); dropped status events
 *    have no cursor of their own.
 * Returns ANY_SHIM_ERR_CLOSED once the account is closed, also to a call
 * blocked at that moment. Meant for one dedicated poller thread. */
any_shim_status any_shim_events_poll(uint64_t account, int32_t max_events,
                                     int32_t timeout_ms, char **out_json,
                                     char **out_error);

/* --------------------------------------------- local index (never synced) */

/* opts_json:
 *   path          string, required: the any-store database file
 *   dim           int, required, > 0
 *   metric        "cosine" (default) | "l2" | "dot"
 *   mode          "exact" (default: brute force, exact recall) |
 *                 "hnsw" (approximate; filtered queries retried, see knn).
 *                 Any other mode (IVF-SQ cannot train on an empty
 *                 collection) is ANY_SHIM_ERR_REFUSED.
 *   hnsw          {"m","efConstruction","efSearch"}, optional
 *   filterFields  [string]: meta.<field> gets a range index
 *   passphrase    string, optional: page-level AES-256-GCM of the file;
 *                 a database created with one needs it on every open
 * A database opened earlier with other options (dim, metric, mode, hnsw,
 * filterFields) is ANY_SHIM_ERR_INVALID_ARGUMENT: any-store keeps an index
 * as it was built. */
any_shim_status any_shim_index_open(char *opts_json, uint64_t *out_index,
                                    char **out_error);

any_shim_status any_shim_index_close(uint64_t index, char **out_error);

/* doc_json: {"id" (required), "name", "text", "meta":{...}}; vector of
 * length dim (the index's). Replaces a document with the same id. */
any_shim_status any_shim_index_upsert(uint64_t index, char *doc_json,
                                      float *vector, int32_t dim,
                                      char **out_error);

/* *out_found = 1 when the id was there, 0 otherwise (not an error). */
any_shim_status any_shim_index_delete(uint64_t index, char *id,
                                      int32_t *out_found, char **out_error);

any_shim_status any_shim_index_count(uint64_t index, int64_t *out_count,
                                     char **out_error);

/* k nearest documents, optionally under a Mongo-style filter on the
 * stored fields (e.g. {"meta.cat":"food"}).
 * {"results":[{"id","name","text","meta","distance"}],"ef","attempts",
 *  "complete"}
 * In "hnsw" mode a filtered query that returns fewer than k while the
 * collection holds more is re-run with a doubled ef, up to the collection
 * size; "ef" (0 = any-store's default) and "attempts" report what the last
 * run used. That happens when any-store filters the ANN candidates (a
 * filter field without a range index); a filter on a filterFields key is
 * evaluated exactly by any-store itself. "complete" is false when the
 * retries reached any-store's ef ceiling short of the collection size with
 * fewer than k results: there may be more matches than returned. */
any_shim_status any_shim_index_knn(uint64_t index, float *query,
                                   int32_t dim, int32_t k,
                                   char *filter_json, char **out_json,
                                   char **out_error);

/* BM25 over name + text. {"results":[{"id","name","text","meta","score"}]} */
any_shim_status any_shim_index_text(uint64_t index, char *query,
                                    int32_t k, char *filter_json,
                                    char **out_json, char **out_error);

/* Small string values next to the index (cursor, generation).
 * get: *out_value = NULL when the key is not set. */
any_shim_status any_shim_index_state_get(uint64_t index, char *key,
                                         char **out_value, char **out_error);
any_shim_status any_shim_index_state_set(uint64_t index, char *key,
                                         char *value, char **out_error);

#ifdef __cplusplus
}
#endif

#endif /* ANY_SHIM_H_ */
