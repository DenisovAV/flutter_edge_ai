// Host test of mediatek_dispatch_compat.c (run_mediatek_dispatch_compat_test.sh).
//
// Built twice from this file:
//   -DFAKE_LEGACY       a legacy dispatch (LiteRT 26895c9f layout) exporting
//                       only LiteRtDispatchGetApi; every slot is a distinct
//                       function returning 100 + its position. With
//                       -DFAKE_NO_OPTIONAL the async and graph tables and the
//                       buffer handlers are NULL, as in Google's MediaTek AAR.
//   (no define)         the runner: opens the adapter, negotiates each
//                       interface the way LiteRT dcb657e8 does (header size,
//                       major 1, LITERT_ABI_HAS_API) and calls every slot BY
//                       NAME, so a table copied one slot off fails. With
//                       -DWITH_LITERT_HEADERS the V1 structs come from the
//                       real litert/vendors/c/litert_dispatch_api.h instead
//                       of the declarations below.
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Field names, in order, as in litert/vendors/c/litert_dispatch_api.h.
#define BASIC_FIELDS(X)                                                     \
  X(initialize) X(get_vendor_id) X(get_build_id) X(get_capabilities)        \
  X(device_context_create) X(device_context_destroy)                        \
  X(get_input_requirements) X(get_output_requirements)                      \
  X(register_tensor_buffer) X(unregister_tensor_buffer)                     \
  X(invocation_context_create) X(invocation_context_destroy)                \
  X(invocation_context_set_scheduling_info) X(attach_input)                 \
  X(attach_output) X(detach_input) X(detach_output) X(invoke)               \
  X(start_metrics_collection) X(stop_metrics_collection)                    \
  X(get_num_metrics) X(get_metric) X(destroy_metrics)                       \
  X(check_runtime_compatibility) X(invocation_context_set_options)          \
  X(get_hooks)
#define ASYNC_FIELDS(X) X(attach_input_event) X(invoke_async)
#define GRAPH_FIELDS(X)                                                     \
  X(graph_create) X(graph_destroy) X(add_node) X(add_edge)                  \
  X(connect_node_input) X(connect_node_output) X(connect_graph_input)       \
  X(connect_graph_output) X(load_executable) X(unload_executable)           \
  X(assign_node_function) X(annotate_graph) X(annotate_node)                \
  X(annotate_edge) X(invocation_context_create_from_graph)                  \
  X(invocation_context_get_graph)

typedef void (*Fn)(void);
#define DECLARE(name) Fn name;

#ifdef FAKE_LEGACY
// ---------------------------------------------------------------------------
// The legacy dispatch.
typedef struct {
  uint16_t struct_size, major_version, minor_version, reserved;
} AbiHeader;
typedef struct {
  int major, minor, patch;
} ApiVersion;
typedef struct { BASIC_FIELDS(DECLARE) } LegacyBasic;
typedef struct { ASYNC_FIELDS(DECLARE) } LegacyAsync;
typedef struct { GRAPH_FIELDS(DECLARE) } LegacyGraph;
typedef struct {
  AbiHeader abi_header;
  ApiVersion version;
  LegacyBasic* interface;
  LegacyAsync* async_interface;
  LegacyGraph* graph_interface;
  AbiHeader* tensor_buffer_handlers_def;
} LegacyApi;
_Static_assert(sizeof(LegacyApi) == 56, "LiteRtDispatchApi is 56 bytes");

#define SLOT(i) \
  static int slot##i(void) { return 100 + i; }
SLOT(0) SLOT(1) SLOT(2) SLOT(3) SLOT(4) SLOT(5) SLOT(6) SLOT(7) SLOT(8)
SLOT(9) SLOT(10) SLOT(11) SLOT(12) SLOT(13) SLOT(14) SLOT(15) SLOT(16)
SLOT(17) SLOT(18) SLOT(19) SLOT(20) SLOT(21) SLOT(22) SLOT(23) SLOT(24)
SLOT(25) SLOT(26) SLOT(27) SLOT(28) SLOT(29) SLOT(30) SLOT(31) SLOT(32)
SLOT(33) SLOT(34) SLOT(35) SLOT(36) SLOT(37) SLOT(38) SLOT(39) SLOT(40)
SLOT(41) SLOT(42) SLOT(43)
static int (*const kSlots[44])(void) = {
    slot0,  slot1,  slot2,  slot3,  slot4,  slot5,  slot6,  slot7,  slot8,
    slot9,  slot10, slot11, slot12, slot13, slot14, slot15, slot16, slot17,
    slot18, slot19, slot20, slot21, slot22, slot23, slot24, slot25, slot26,
    slot27, slot28, slot29, slot30, slot31, slot32, slot33, slot34, slot35,
    slot36, slot37, slot38, slot39, slot40, slot41, slot42, slot43};

static LegacyBasic basic;
static LegacyAsync async_iface;
static LegacyGraph graph;
#ifndef FAKE_NO_OPTIONAL
static AbiHeader handlers = {136, 1, 0, 0};
#endif

__attribute__((visibility("default"))) int LiteRtDispatchGetApi(
    LegacyApi* api) {
  Fn* b = (Fn*)&basic;  // slots 0..25
  for (int i = 0; i < 26; ++i) b[i] = (Fn)kSlots[i];
  Fn* a = (Fn*)&async_iface;  // 26..27
  for (int i = 0; i < 2; ++i) a[i] = (Fn)kSlots[26 + i];
  Fn* g = (Fn*)&graph;  // 28..43
  for (int i = 0; i < 16; ++i) g[i] = (Fn)kSlots[28 + i];
  memset(api, 0, sizeof(*api));
  api->version = (ApiVersion){0, 1, 0};
  api->interface = &basic;
#ifndef FAKE_NO_OPTIONAL
  api->async_interface = &async_iface;
  api->graph_interface = &graph;
  api->tensor_buffer_handlers_def = &handlers;
#endif
  return 0;
}

#else
// ---------------------------------------------------------------------------
// The runner.
#ifdef WITH_LITERT_HEADERS
#include "litert/vendors/c/litert_dispatch_api.h"
typedef LiteRtAbiHeader AbiHeader;
typedef LiteRtApiVersion ApiVersion;
typedef LiteRtDispatchInterface_V1 BasicV1;
typedef LiteRtDispatchAsyncInterface_V1 AsyncV1;
typedef LiteRtDispatchGraphInterface_V1 GraphV1;
#else
typedef struct {
  uint16_t struct_size, major_version, minor_version, reserved;
} AbiHeader;
typedef struct {
  int major, minor, patch;
} ApiVersion;
typedef struct {
  AbiHeader abi_header;
  BASIC_FIELDS(DECLARE)
  Fn attach_edge_buffer;
  Fn detach_edge_buffer;
} BasicV1;
typedef struct {
  AbiHeader abi_header;
  ASYNC_FIELDS(DECLARE)
} AsyncV1;
typedef struct {
  AbiHeader abi_header;
  GRAPH_FIELDS(DECLARE)
  Fn get_scratchpad_requirements;
  Fn attach_scratchpad_buffer;
} GraphV1;
#endif

typedef int (*QueryFn)(int, ApiVersion, const void**);
static int failures = 0;

#define CHECK(cond, ...)               \
  do {                                 \
    if (!(cond)) {                     \
      printf("FAIL: " __VA_ARGS__);    \
      printf("\n");                    \
      ++failures;                      \
    }                                  \
  } while (0)

// NegotiateInterface (litert/core/version.h) plus the size check behind
// LITERT_ABI_HAS_MEMBER for the last member the table must hold.
static const void* Negotiate(QueryFn q, int id, size_t needed) {
  const void* iface = NULL;
  ApiVersion v = {1, 0, 0};
  if (q(id, v, &iface) != 0 || iface == NULL) return NULL;
  const AbiHeader* h = (const AbiHeader*)iface;
  if (h->struct_size < sizeof(AbiHeader) || h->major_version != 1) return NULL;
  if (h->struct_size < needed) return NULL;
  return iface;
}

static int Call(Fn f) { return f ? ((int (*)(void))f)() : -1; }

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <adapter.so> full|minimal\n", argv[0]);
    return 2;
  }
  int full = strcmp(argv[2], "full") == 0;
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    printf("FAIL: dlopen: %s\n", dlerror());
    return 1;
  }
  CHECK(dlsym(h, "LiteRtDispatchGetApi") == NULL,
        "the adapter exports the legacy entry point");
  QueryFn q = (QueryFn)dlsym(h, "LiteRtDispatchQueryInterface");
  if (!q) {
    printf("FAIL: no LiteRtDispatchQueryInterface\n");
    return 1;
  }

  const BasicV1* b = Negotiate(q, 0, sizeof(BasicV1));
  if (!b) {
    printf("FAIL: basic interface not negotiated\n");
    return 1;
  }
  int i = 0;
#define CHECK_SLOT(name) \
  CHECK(Call((Fn)b->name) == 100 + i, "basic." #name " -> %d", Call((Fn)b->name)); \
  ++i;
  BASIC_FIELDS(CHECK_SLOT)
#undef CHECK_SLOT
  CHECK(b->attach_edge_buffer == NULL && b->detach_edge_buffer == NULL,
        "edge buffer slots are not NULL");

  const AsyncV1* a = Negotiate(q, 1, sizeof(AsyncV1));
  const GraphV1* g = Negotiate(q, 2, sizeof(GraphV1));
  const void* t = Negotiate(q, 3, sizeof(AbiHeader));
  if (full) {
    CHECK(a != NULL, "async interface not negotiated");
    CHECK(g != NULL, "graph interface not negotiated");
    CHECK(t != NULL, "buffer handlers not negotiated");
    if (a) {
      i = 26;
#define CHECK_SLOT(name) \
  CHECK(Call((Fn)a->name) == 100 + i, "async." #name " -> %d", Call((Fn)a->name)); \
  ++i;
      ASYNC_FIELDS(CHECK_SLOT)
#undef CHECK_SLOT
    }
    if (g) {
      i = 28;
#define CHECK_SLOT(name) \
  CHECK(Call((Fn)g->name) == 100 + i, "graph." #name " -> %d", Call((Fn)g->name)); \
  ++i;
      GRAPH_FIELDS(CHECK_SLOT)
#undef CHECK_SLOT
      CHECK(g->get_scratchpad_requirements == NULL &&
                g->attach_scratchpad_buffer == NULL,
            "scratchpad slots are not NULL");
    }
  } else {
    CHECK(a == NULL && g == NULL && t == NULL,
          "a NULL legacy table was offered as an interface");
  }
  CHECK(Negotiate(q, 4, 0) == NULL, "an unknown interface id was answered");

  printf("%s %s\n", failures ? "FAIL" : "PASS", argv[2]);
  return failures ? 1 : 0;
}
#endif
