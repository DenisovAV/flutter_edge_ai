// Package main is libany_shim: the C ABI declared in include/any_shim.h,
// over any-sync-sdk and an any-store v2 local index. Built with
// -buildmode=c-shared (macOS, Linux, Windows, Android) or c-archive (iOS,
// linked into a dylib by build.sh).
//
// Every export goes through guard(), which recovers a panic and turns any
// error into a status code plus a message. Results are written to the
// out-parameters only on success.
package main

/*
#cgo CFLAGS: -I${SRCDIR}/include
#include <stdlib.h>
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"runtime"
	"runtime/debug"
	"unsafe"

	"github.com/anyproto/any-sync-sdk/auth"
)

// abiVersion must equal ANY_SHIM_ABI_VERSION; TestAbiVersionMatchesHeader
// holds them together.
const abiVersion = 1

// shimVersion names this shim's own release, independent of the SDK's.
const shimVersion = "0.1.0"

//export any_shim_abi_version
func any_shim_abi_version() C.uint32_t { return C.uint32_t(abiVersion) }

//export any_shim_free
func any_shim_free(ptr unsafe.Pointer) { C.free(ptr) }

// guard runs f, recovering a panic, and reports its error through
// outErr. It is the only way an export returns a status.
func guard(outErr **C.char, f func() error) (status C.any_shim_status) {
	defer func() {
		if r := recover(); r != nil {
			status = report(outErr, &shimError{code: codePanic,
				err: fmt.Errorf("panic: %v\n%s", r, debug.Stack())})
		}
	}()
	return report(outErr, f())
}

func report(outErr **C.char, err error) C.any_shim_status {
	if err == nil {
		return C.ANY_SHIM_OK
	}
	if outErr != nil {
		*outErr = C.CString(err.Error())
	}
	return C.any_shim_status(codeOf(err))
}

// goStr reads a C string; NULL is "".
func goStr(p *C.char) string {
	if p == nil {
		return ""
	}
	return C.GoString(p)
}

func putStr(out **C.char, name, s string) error {
	if out == nil {
		return invalid("%s is NULL", name)
	}
	*out = C.CString(s)
	return nil
}

func putJSON(out **C.char, v any) error {
	if out == nil {
		return invalid("out_json is NULL")
	}
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	*out = C.CString(string(b))
	return nil
}

func versionInfo() map[string]any {
	mods := map[string]string{}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, d := range bi.Deps {
			switch d.Path {
			case "github.com/anyproto/any-sync-sdk",
				"github.com/anyproto/any-sync",
				"github.com/anyproto/any-store/v2":
				v := d.Version
				if d.Replace != nil {
					v += " => " + d.Replace.Path + " " + d.Replace.Version
				}
				mods[d.Path] = v
			}
		}
	}
	return map[string]any{
		"abi":     abiVersion,
		"shim":    shimVersion,
		"go":      runtime.Version(),
		"modules": mods,
	}
}

//export any_shim_version
func any_shim_version(outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error { return putJSON(outJSON, versionInfo()) })
}

//export any_shim_new_mnemonic
func any_shim_new_mnemonic(outMnemonic, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		m, err := auth.GenerateMnemonic()
		if err != nil {
			return err
		}
		return putStr(outMnemonic, "out_mnemonic", m)
	})
}

//export any_shim_new_device_key
func any_shim_new_device_key(outHex, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		k, err := auth.GenerateDeviceKey(context.Background())
		if err != nil {
			return err
		}
		return putStr(outHex, "out_hex", hex.EncodeToString(k))
	})
}

func main() {}
