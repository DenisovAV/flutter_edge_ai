// libLiteRtDispatch_MediaTek.so: the versioned dispatch ABI over Google's
// legacy MediaTek dispatch.
//
// LiteRT f59b79337 (in the LiteRT pin of LiteRT-LM v0.19.0) loads a dispatch
// only through LiteRtDispatchQueryInterface, with no fallback. Google's
// litert-npu-runtime-mediatek AAR (2.3.0, 2.3.2) exports only the legacy
// LiteRtDispatchGetApi, and we cannot build that dispatch ourselves: it
// compiles against MediaTek's NeuroPilot SDK, which may reach users only
// inside an app. So the build hook stores Google's library as LEGACY_NAME, a
// name LiteRT's dispatch scan (any file containing "libLiteRtDispatch", in
// subdirectories too) never matches, next to this one; this library opens it
// from its own directory and answers QueryInterface with V1 tables built from
// the legacy ones.
//
// The two ABIs hold the same function pointers in the same order with the
// same signatures (LiteRT 26895c9f vs dcb657e8, litert/vendors/c/
// litert_dispatch_api.h). V1 puts a LiteRtAbiHeader in front of each table
// and makes the two edge-buffer (basic) and scratchpad (graph) slots
// unconditional, which a legacy dispatch never fills; they stay NULL, which
// the runtime reads as "not supported". The custom tensor buffer handlers
// struct already carried its header and is passed through as it is.
// LiteRtRuntimeContext, which the dispatch calls back through, is
// byte-identical at both pins, and the runtime C API table it points to only
// grew at the end. doc/research/mediatek-dispatch-0.19.md has the comparison.
//
// No LiteRT or NeuroPilot header is included: the layouts are declared here
// and checked against the real header by run_mediatek_dispatch_compat_test.sh
// (LITERT_DIR). Remove this library once Google publishes a MediaTek dispatch
// built against the versioned ABI.
#define _GNU_SOURCE

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef LEGACY_NAME
#define LEGACY_NAME "libmtk_litert_dispatch_legacy.so"
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

// LiteRtStatus values (litert/c/litert_common.h).
typedef int LiteRtStatus;
enum {
  kStatusOk = 0,
  kStatusInvalidArgument = 1,
  kStatusRuntimeFailure = 3,
  kStatusUnsupported = 5,
  kStatusNotFound = 6,
};

typedef struct {
  uint16_t struct_size, major_version, minor_version, reserved;
} AbiHeader;
typedef struct {
  int major, minor, patch;
} ApiVersion;
typedef void (*Fn)(void);

// Legacy tables (LiteRT 26895c9f), without LITERT_ENABLE_FABRIC_INTEGRATION.
#define BASIC_SLOTS 26  // initialize .. get_hooks
#define ASYNC_SLOTS 2   // attach_input_event, invoke_async
#define GRAPH_SLOTS 16  // graph_create .. invocation_context_get_graph
typedef struct {
  AbiHeader abi_header;
  ApiVersion version;
  const Fn* interface;
  const Fn* async_interface;
  const Fn* graph_interface;
  const AbiHeader* tensor_buffer_handlers_def;
} LegacyApi;
_Static_assert(sizeof(LegacyApi) == 56, "LiteRtDispatchApi is 56 bytes");
_Static_assert(offsetof(LegacyApi, interface) == 24, "interface at 24");

// V1 tables (LiteRT dcb657e8): the header, the legacy slots, then the slots
// that were behind the fabric flag.
typedef struct {
  AbiHeader h;
  Fn f[BASIC_SLOTS];
  Fn attach_edge_buffer, detach_edge_buffer;
} BasicV1;
typedef struct {
  AbiHeader h;
  Fn f[ASYNC_SLOTS];
} AsyncV1;
typedef struct {
  AbiHeader h;
  Fn f[GRAPH_SLOTS];
  Fn get_scratchpad_requirements, attach_scratchpad_buffer;
} GraphV1;

// LiteRtDispatchInterfaceId.
enum { kBasic = 0, kAsync = 1, kGraph = 2, kCustomTensorBufferHandlers = 3 };

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static LiteRtStatus g_status = kStatusRuntimeFailure;
static LegacyApi g_legacy;
static BasicV1 g_basic;
static AsyncV1 g_async;
static GraphV1 g_graph;

static void Load(void) {
  Dl_info info;
  if (!dladdr((const void*)&Load, &info) || info.dli_fname == NULL) return;
  const char* slash = strrchr(info.dli_fname, '/');
  size_t dir = slash ? (size_t)(slash - info.dli_fname + 1) : 0;
  char path[PATH_MAX];
  if (dir + sizeof(LEGACY_NAME) > sizeof(path)) return;
  memcpy(path, info.dli_fname, dir);
  memcpy(path + dir, LEGACY_NAME, sizeof(LEGACY_NAME));
  // Never closed: the runtime keeps this library loaded (RTLD_NODELETE).
  void* legacy = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (legacy == NULL) {
    g_status = kStatusNotFound;
    return;
  }
  LiteRtStatus (*get_api)(LegacyApi*) =
      (LiteRtStatus(*)(LegacyApi*))dlsym(legacy, "LiteRtDispatchGetApi");
  if (get_api == NULL) {
    g_status = kStatusNotFound;
    return;
  }
  LiteRtStatus status = get_api(&g_legacy);
  if (status != kStatusOk) {
    g_status = status;
    return;
  }
  if (g_legacy.interface == NULL) return;
  g_basic.h = (AbiHeader){sizeof(BasicV1), 1, 0, 0};
  memcpy(g_basic.f, g_legacy.interface, sizeof(g_basic.f));
  if (g_legacy.async_interface != NULL) {
    g_async.h = (AbiHeader){sizeof(AsyncV1), 1, 0, 0};
    memcpy(g_async.f, g_legacy.async_interface, sizeof(g_async.f));
  }
  if (g_legacy.graph_interface != NULL) {
    g_graph.h = (AbiHeader){sizeof(GraphV1), 1, 0, 0};
    memcpy(g_graph.f, g_legacy.graph_interface, sizeof(g_graph.f));
  }
  g_status = kStatusOk;
}

__attribute__((visibility("default"))) LiteRtStatus
LiteRtDispatchQueryInterface(int interface_id, ApiVersion runtime_version,
                             const void** out_interface) {
  (void)runtime_version;
  if (out_interface == NULL) return kStatusInvalidArgument;
  *out_interface = NULL;
  pthread_once(&g_once, Load);
  if (g_status != kStatusOk) return g_status;
  switch (interface_id) {
    case kBasic:
      *out_interface = &g_basic;
      return kStatusOk;
    case kAsync:
      if (g_legacy.async_interface == NULL) return kStatusUnsupported;
      *out_interface = &g_async;
      return kStatusOk;
    case kGraph:
      if (g_legacy.graph_interface == NULL) return kStatusUnsupported;
      *out_interface = &g_graph;
      return kStatusOk;
    case kCustomTensorBufferHandlers:
      if (g_legacy.tensor_buffer_handlers_def == NULL) {
        return kStatusUnsupported;
      }
      *out_interface = g_legacy.tensor_buffer_handlers_def;
      return kStatusOk;
    default:
      return kStatusUnsupported;
  }
}
