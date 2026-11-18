package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/anyproto/any-sync-sdk/space"
)

func (a *account) fileAttach(spaceId, objId, path, name string) (space.FileInfo, error) {
	if objId == "" || path == "" {
		return space.FileInfo{}, invalid("object id and path are required")
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return space.FileInfo{}, err
	}
	f, err := os.Open(path)
	if err != nil {
		return space.FileInfo{}, invalid("open %s: %v", path, err)
	}
	defer f.Close()
	if name == "" {
		name = filepath.Base(path)
	}
	return sp.Files().Attach(a.ctx, objId, f, space.AttachOpts{Name: name})
}

func (a *account) fileList(spaceId, objId string) ([]space.FileInfo, error) {
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	return sp.Files().List(a.ctx, space.FileListOpts{ObjectId: objId})
}

func (a *account) fileStatus(spaceId, fileId string) (space.FileStatus, error) {
	if fileId == "" {
		return space.FileStatus{}, invalid("file id is empty")
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return space.FileStatus{}, err
	}
	return sp.Files().Status(a.ctx, fileId)
}

// fileRead copies the file to outPath through a temp file in the same
// directory, so a failed or timed-out fetch never leaves a partial file
// under the requested name.
func (a *account) fileRead(spaceId, fileId, outPath string, timeout time.Duration) (int64, error) {
	if fileId == "" || outPath == "" {
		return 0, invalid("file id and out path are required")
	}
	ctx := a.ctx
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return 0, err
	}
	r, err := sp.Files().Open(ctx, fileId, space.VariantOriginal)
	if err != nil {
		return 0, timeoutOr(ctx, err)
	}
	defer r.Close()
	tmp, err := os.CreateTemp(filepath.Dir(outPath), ".any_shim_read_*")
	if err != nil {
		return 0, invalid("create in %s: %v", filepath.Dir(outPath), err)
	}
	keep := false
	defer func() {
		if !keep {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	n, err := io.Copy(tmp, readerWithContext{ctx, r})
	if err != nil {
		return 0, timeoutOr(ctx, fmt.Errorf("read file %s: %w", fileId, err))
	}
	if err := tmp.Close(); err != nil {
		return 0, err
	}
	if err := os.Rename(tmp.Name(), outPath); err != nil {
		return 0, err
	}
	keep = true
	return n, nil
}

// timeoutOr reports a deadline as the timeout it was, whatever error the
// SDK wrapped it in.
func timeoutOr(ctx context.Context, err error) error {
	if ctx.Err() == context.DeadlineExceeded {
		return withCode(codeTimeout, "deadline passed: %v", err)
	}
	return err
}

// readerWithContext stops a copy between reads once ctx is done; the
// SDK's reader takes no context of its own.
type readerWithContext struct {
	ctx context.Context
	r   io.Reader
}

func (r readerWithContext) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(p)
}

func fileInfoJSON(fi space.FileInfo) map[string]any {
	return map[string]any{
		"fileId": fi.FileId, "objectId": fi.ObjectId, "rootCid": fi.RootCid,
		"size": fi.Size, "inline": fi.Inline, "durable": fi.Durable,
		"name": fi.Name, "mime": fi.Mime, "cached": fi.Cached,
	}
}

func fileStatusJSON(st space.FileStatus) map[string]any {
	return map[string]any{
		"fileId": st.FileId, "objectId": st.ObjectId, "state": string(st.State),
		"cached": st.Cached, "attempts": st.Attempts, "lastError": st.LastErr,
	}
}

// ---------------------------------------------------------------- exports

//export any_shim_file_attach
func any_shim_file_attach(h C.uint64_t, spaceID, objectID, path, name *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			fi, err := a.fileAttach(goStr(spaceID), goStr(objectID), goStr(path), goStr(name))
			if err != nil {
				return err
			}
			return putJSON(outJSON, fileInfoJSON(fi))
		})
	})
}

//export any_shim_file_list
func any_shim_file_list(h C.uint64_t, spaceID, objectID *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			l, err := a.fileList(goStr(spaceID), goStr(objectID))
			if err != nil {
				return err
			}
			out := make([]map[string]any, 0, len(l))
			for _, fi := range l {
				out = append(out, fileInfoJSON(fi))
			}
			return putJSON(outJSON, out)
		})
	})
}

//export any_shim_file_status
func any_shim_file_status(h C.uint64_t, spaceID, fileID *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			st, err := a.fileStatus(goStr(spaceID), goStr(fileID))
			if err != nil {
				return err
			}
			return putJSON(outJSON, fileStatusJSON(st))
		})
	})
}

//export any_shim_file_read
func any_shim_file_read(h C.uint64_t, spaceID, fileID, outPath *C.char, timeoutMs C.int32_t, outBytes *C.int64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if outBytes == nil {
				return invalid("out_bytes is NULL")
			}
			n, err := a.fileRead(goStr(spaceID), goStr(fileID), goStr(outPath), time.Duration(timeoutMs)*time.Millisecond)
			if err != nil {
				return err
			}
			*outBytes = C.int64_t(n)
			return nil
		})
	})
}
