package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// stateFileName is the account state the shim keeps next to the SDK's
// own files in dataDir: what this device knows about each space that
// the SDK does not record.
const stateFileName = "any_shim_state.json"

type spaceState struct {
	// CreatedHere: the space was created on this device.
	CreatedHere bool `json:"createdHere,omitempty"`
	// EverPeerSynced: a peer sync of the space completed on this device
	// at least once (LastSyncedAt became non-zero, or a sync_heads round
	// reached a peer). Never cleared.
	EverPeerSynced bool `json:"everPeerSynced,omitempty"`
}

type accountStateDoc struct {
	Fmt    int                    `json:"fmt"`
	Spaces map[string]*spaceState `json:"spaces"`
}

// accountState is the persisted account state. Writes are atomic (temp
// file, fsync, rename, fsync of the directory) and serialised; a flag is
// set in memory first, so a reader never waits for the disk.
type accountState struct {
	path string

	mu     sync.Mutex
	doc    accountStateDoc
	saveMu sync.Mutex // one writer at a time; held across the file write
	wg     sync.WaitGroup
	err    error // the last save's error (nil when it succeeded)
	// version counts changes; saved is the version the last successful
	// save wrote. saved < version: the disk is behind (dirty).
	version, saved uint64
}

func loadAccountState(dataDir string) (*accountState, error) {
	s := &accountState{path: filepath.Join(dataDir, stateFileName),
		doc: accountStateDoc{Fmt: 1, Spaces: map[string]*spaceState{}}}
	b, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, ioOr(err, codeInternal, "read %s", s.path)
	}
	var d accountStateDoc
	if err := json.Unmarshal(b, &d); err != nil {
		return nil, withCode(codeCorrupt, "%s: %v", s.path, err)
	}
	if d.Fmt != 1 {
		return nil, withCode(codeCorrupt, "%s has format %d; this build knows 1", s.path, d.Fmt)
	}
	if d.Spaces == nil {
		d.Spaces = map[string]*spaceState{}
	}
	s.doc = d
	return s, nil
}

func (s *accountState) get(spaceId string) spaceState {
	s.mu.Lock()
	defer s.mu.Unlock()
	if st := s.doc.Spaces[spaceId]; st != nil {
		return *st
	}
	return spaceState{}
}

// update applies f to the space's entry and, when it changed anything,
// saves. sync=false saves on a goroutine (for callbacks on the SDK's
// dispatcher, which must not wait for the disk); close waits for it.
func (s *accountState) update(spaceId string, sync bool, f func(st *spaceState)) error {
	s.mu.Lock()
	st := s.doc.Spaces[spaceId]
	if st == nil {
		st = &spaceState{}
	}
	before := *st
	f(st)
	changed := *st != before
	if changed {
		s.doc.Spaces[spaceId] = st
		s.version++
	}
	dirty := s.version != s.saved
	s.mu.Unlock()
	if !changed && sync {
		// Nothing new, but the caller needs the flag on disk: wait for
		// saves in flight, and save again if the disk is still behind.
		s.wg.Wait()
		s.mu.Lock()
		dirty = s.version != s.saved
		s.mu.Unlock()
		if !dirty {
			return nil
		}
		return s.save()
	}
	if !dirty {
		return nil
	}
	if sync {
		return s.save()
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		_ = s.save()
	}()
	return nil
}

// save writes the whole state; its outcome is the state's save error
// (the last save decides: a later success clears it).
func (s *accountState) save() error {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()
	s.mu.Lock()
	b, err := json.Marshal(s.doc)
	v := s.version
	s.mu.Unlock()
	if err == nil {
		if werr := writeFileAtomic(s.path, b); werr != nil {
			err = ioOr(werr, codeInternal, "save %s", s.path)
		}
	}
	s.mu.Lock()
	s.err = err
	if err == nil && v > s.saved {
		s.saved = v
	}
	s.mu.Unlock()
	return err
}

// saveError is the error of the last save, nil when it succeeded.
func (s *accountState) saveError() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

// flush waits for background saves and, if the disk is still behind (a
// background save failed), saves again; it reports that result.
func (s *accountState) flush() error {
	s.wg.Wait()
	s.mu.Lock()
	dirty := s.version != s.saved
	err := s.err
	s.mu.Unlock()
	if dirty {
		return s.save()
	}
	return err
}

// writeFileAtomic writes path through a temp file in its directory:
// write, fsync, rename, fsync the directory. A crash leaves the old file
// or the new one, never a torn one; a stale temp file is overwritten by
// the next write.
func writeFileAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}

// syncDir fsyncs a directory so a rename in it is durable. Windows has
// no directory fsync (opening a directory fails); NTFS journals renames.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		if isWindows {
			return nil
		}
		return fmt.Errorf("open %s for fsync: %w", dir, err)
	}
	defer d.Close()
	if err := d.Sync(); err != nil && !isWindows {
		return err
	}
	return nil
}
