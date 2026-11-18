/*
 * device_smoke.c: loads libany_shim with dlopen on a device and runs the
 * offline path once (no network: p2p off, a nodeconf of closed ports).
 * For a target where the Dart tests cannot run yet, e.g. an Android
 * emulator over adb:
 *
 *   $NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang \
 *       -o device_smoke tools/device_smoke.c -ldl
 *   adb push device_smoke libany_shim.so testdata/nodeconf-dead.yml /data/local/tmp/any/
 *   adb shell 'cd /data/local/tmp/any && ./device_smoke ./libany_shim.so nodeconf-dead.yml .'
 *
 * Prints one line per step and "PASS" at the end; exits non-zero on the
 * first failure.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/any_shim.h"

static void *lib;
#define BIND(name) \
  __typeof__(&name) p_##name = (__typeof__(&name))dlsym(lib, #name); \
  if (!p_##name) { printf("FAIL dlsym %s: %s\n", #name, dlerror()); return 1; }

#define CHECK(call, what)                                                  \
  do {                                                                     \
    char *err = NULL;                                                      \
    any_shim_status st = (call);                                           \
    if (st != ANY_SHIM_OK) {                                               \
      printf("FAIL %s: status %d: %s\n", what, st, err ? err : "(none)"); \
      return 1;                                                            \
    }                                                                      \
  } while (0)

static char *read_file(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc(n + 1);
  fread(buf, 1, n, f);
  buf[n] = 0;
  fclose(f);
  return buf;
}

/* Appends s to out as a JSON string literal. */
static void json_str(char *out, const char *s) {
  char *o = out + strlen(out);
  *o++ = '"';
  for (; *s; s++) {
    if (*s == '"' || *s == '\\') { *o++ = '\\'; *o++ = *s; }
    else if (*s == '\n') { *o++ = '\\'; *o++ = 'n'; }
    else *o++ = *s;
  }
  *o++ = '"';
  *o = 0;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    printf("usage: %s <libany_shim> <nodeconf.yml> <work dir>\n", argv[0]);
    return 2;
  }
  lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!lib) { printf("FAIL dlopen: %s\n", dlerror()); return 1; }
  BIND(any_shim_abi_version) BIND(any_shim_free) BIND(any_shim_version)
  BIND(any_shim_new_mnemonic) BIND(any_shim_new_device_key)
  BIND(any_shim_account_open) BIND(any_shim_account_close)
  BIND(any_shim_space_create) BIND(any_shim_object_put) BIND(any_shim_object_get)
  BIND(any_shim_index_open) BIND(any_shim_index_upsert) BIND(any_shim_index_knn)
  BIND(any_shim_index_close)

  printf("abi %u\n", p_any_shim_abi_version());
  if (p_any_shim_abi_version() != ANY_SHIM_ABI_VERSION) { printf("FAIL abi\n"); return 1; }
  char *v = NULL, *mn = NULL, *dk = NULL;
  CHECK(p_any_shim_version(&v, &err), "version");
  printf("version %s\n", v);
  CHECK(p_any_shim_new_mnemonic(&mn, &err), "mnemonic");
  CHECK(p_any_shim_new_device_key(&dk, &err), "device key");

  /* Local index. */
  static char opts[65536];
  snprintf(opts, sizeof opts, "{\"path\":\"%s/idx.db\",\"dim\":3,\"filterFields\":[\"cat\"]}", argv[3]);
  uint64_t idx = 0;
  CHECK(p_any_shim_index_open(opts, &idx, &err), "index open");
  float a[3] = {1, 0, 0}, b[3] = {0, 1, 0};
  CHECK(p_any_shim_index_upsert(idx, "{\"id\":\"a\",\"name\":\"Rocket\",\"meta\":{\"cat\":\"space\"}}", a, 3, &err), "upsert a");
  CHECK(p_any_shim_index_upsert(idx, "{\"id\":\"b\",\"name\":\"Bread\",\"meta\":{\"cat\":\"food\"}}", b, 3, &err), "upsert b");
  char *knn = NULL;
  CHECK(p_any_shim_index_knn(idx, a, 3, 1, "{\"meta.cat\":\"food\"}", &knn, &err), "knn");
  printf("knn %s\n", knn);
  if (!strstr(knn, "\"id\":\"b\"")) { printf("FAIL knn result\n"); return 1; }
  CHECK(p_any_shim_index_close(idx, &err), "index close");

  /* Account, offline. */
  char *nodeconf = read_file(argv[2]);
  if (!nodeconf) { printf("FAIL read %s\n", argv[2]); return 1; }
  snprintf(opts, sizeof opts, "{\"dataDir\":\"%s/sdk\",\"mnemonic\":\"%s\",\"deviceKeyHex\":\"%s\",\"p2p\":{\"enabled\":false},\"nodeConfYaml\":", argv[3], mn, dk);
  json_str(opts, nodeconf);
  strcat(opts, "}");
  uint64_t acc = 0;
  CHECK(p_any_shim_account_open(opts, &acc, &err), "account open");
  char *sp = NULL, *put = NULL, *got = NULL;
  CHECK(p_any_shim_space_create(acc, "device smoke", &sp, &err), "space create");
  char space_id[256];
  if (sscanf(sp, "{\"id\":\"%255[^\"]\"}", space_id) != 1) { printf("FAIL space json %s\n", sp); return 1; }
  CHECK(p_any_shim_object_put(acc, space_id, "{\"name\":\"Titan\",\"text\":\"methane lakes\",\"meta\":{\"cat\":\"space\"}}", &put, &err), "object put");
  char obj_id[256];
  if (sscanf(put, "{\"created\":true,\"id\":\"%255[^\"]\"}", obj_id) != 1) { printf("FAIL put json %s\n", put); return 1; }
  CHECK(p_any_shim_object_get(acc, space_id, obj_id, &got, &err), "object get");
  if (!strstr(got, "\"text\":\"methane lakes\"")) { printf("FAIL get %s\n", got); return 1; }
  printf("object %s\n", obj_id);
  CHECK(p_any_shim_account_close(acc, &err), "account close");
  p_any_shim_free(v); p_any_shim_free(mn); p_any_shim_free(dk); p_any_shim_free(knn);
  p_any_shim_free(sp); p_any_shim_free(put); p_any_shim_free(got);
  printf("PASS\n");
  return 0;
}
