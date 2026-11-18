package main

import (
	"os"
	"regexp"
	"sort"
	"strconv"
	"testing"
)

func readHeader(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("include/any_shim.h")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestAbiVersionMatchesHeader(t *testing.T) {
	m := regexp.MustCompile(`#define ANY_SHIM_ABI_VERSION (\d+)`).FindStringSubmatch(readHeader(t))
	if m == nil {
		t.Fatal("ANY_SHIM_ABI_VERSION not in the header")
	}
	if m[1] != strconv.Itoa(abiVersion) {
		t.Fatalf("header ABI %s, Go abiVersion %d", m[1], abiVersion)
	}
}

func TestStatusCodesMatchHeader(t *testing.T) {
	want := map[string]int{
		"ANY_SHIM_OK": codeOK, "ANY_SHIM_ERR_INVALID_ARGUMENT": codeInvalidArgument,
		"ANY_SHIM_ERR_NOT_FOUND": codeNotFound, "ANY_SHIM_ERR_DELETED": codeDeleted,
		"ANY_SHIM_ERR_CLOSED": codeClosed, "ANY_SHIM_ERR_TIMEOUT": codeTimeout,
		"ANY_SHIM_ERR_REFUSED": codeRefused, "ANY_SHIM_ERR_INTERNAL": codeInternal,
		"ANY_SHIM_ERR_PANIC": codePanic,
	}
	got := map[string]int{}
	for _, m := range regexp.MustCompile(`#define (ANY_SHIM_(?:OK|ERR_[A-Z_]+)) (\d+)`).FindAllStringSubmatch(readHeader(t), -1) {
		n, _ := strconv.Atoi(m[2])
		got[m[1]] = n
	}
	if len(got) != len(want) {
		t.Fatalf("header has %d status codes, Go %d: %v", len(got), len(want), got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: header %d, Go %d", k, got[k], v)
		}
	}
}

// Every function the header declares is exported by the Go code, and
// nothing else is. (cgo already refuses a signature that differs.)
func TestExportsMatchHeader(t *testing.T) {
	declared := regexp.MustCompile(`(?m)^(?:any_shim_status|uint32_t|void) (any_shim_[a-z0-9_]+)\(`).FindAllStringSubmatch(readHeader(t), -1)
	var h []string
	for _, m := range declared {
		h = append(h, m[1])
	}
	files, _ := os.ReadDir(".")
	var g []string
	re := regexp.MustCompile(`(?m)^//export (any_shim_[a-z0-9_]+)\r?$`) // CRLF on a Windows checkout
	for _, f := range files {
		if f.IsDir() || !regexp.MustCompile(`^[a-z_]+\.go$`).MatchString(f.Name()) {
			continue
		}
		b, _ := os.ReadFile(f.Name())
		for _, m := range re.FindAllStringSubmatch(string(b), -1) {
			g = append(g, m[1])
		}
	}
	sort.Strings(h)
	sort.Strings(g)
	if len(h) == 0 || strconv.Quote(joinLines(h)) != strconv.Quote(joinLines(g)) {
		t.Fatalf("header declares\n%v\nGo exports\n%v", h, g)
	}
	// The release gate (check_exports.py) carries the same list.
	b, err := os.ReadFile("check_exports.py")
	if err != nil {
		t.Fatal(err)
	}
	var py []string
	for _, m := range regexp.MustCompile(`"(any_shim_[a-z0-9_]+)"`).FindAllStringSubmatch(string(b), -1) {
		py = append(py, m[1])
	}
	sort.Strings(py)
	if joinLines(py) != joinLines(h) {
		t.Fatalf("check_exports.py lists\n%v\nheader declares\n%v", py, h)
	}
}

func joinLines(s []string) string {
	out := ""
	for _, x := range s {
		out += x + "\n"
	}
	return out
}
