package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
)

// The keycheck sidecar <index path>.keycheck says which key (if any) the
// local index file was written with, so a wrong key, a missing key and a
// damaged file are told apart without reading any-store's error text: an
// encrypted file opened with the wrong key and one whose first page is
// damaged give the same AEAD failure.
//
//	{"fmt":1,"fileId":"<16 random bytes, hex>","mode":"plain"|"hmac",
//	 "mac":"<hex HMAC-SHA256(key, keycheckLabel || fileId bytes)>"}
//
// The fileId is also stored in the database's meta collection, so a
// sidecar copied next to another file is caught.
const keycheckLabel = "flutter_edge_ai_any/keycheck/v1"

type keycheck struct {
	Fmt    int    `json:"fmt"`
	FileId string `json:"fileId"`
	Mode   string `json:"mode"`
	Mac    string `json:"mac,omitempty"`
}

func keycheckMac(key []byte, fileId string) (string, error) {
	id, err := hex.DecodeString(fileId)
	if err != nil {
		return "", err
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte(keycheckLabel))
	m.Write(id)
	return hex.EncodeToString(m.Sum(nil)), nil
}

func newKeycheck(key []byte) (keycheck, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return keycheck{}, err
	}
	kc := keycheck{Fmt: 1, FileId: hex.EncodeToString(id[:]), Mode: "plain"}
	if key != nil {
		mac, err := keycheckMac(key, kc.FileId)
		if err != nil {
			return keycheck{}, err
		}
		kc.Mode, kc.Mac = "hmac", mac
	}
	return kc, nil
}

func writeKeycheck(path string, kc keycheck) error {
	b, err := json.Marshal(kc)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

// readKeycheck returns nil when the sidecar does not exist. A sidecar
// that does not parse, or names an unknown format or mode, is CORRUPT.
func readKeycheck(path string) (*keycheck, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var kc keycheck
	if err := json.Unmarshal(b, &kc); err != nil {
		return nil, withCode(codeCorrupt, "%s does not parse: %v", path, err)
	}
	if kc.Fmt != 1 {
		return nil, withCode(codeCorrupt, "%s has format %d; this build knows 1", path, kc.Fmt)
	}
	if id, err := hex.DecodeString(kc.FileId); err != nil || len(id) != 16 {
		return nil, withCode(codeCorrupt, "%s: fileId is not 16 bytes of hex", path)
	}
	switch kc.Mode {
	case "plain":
	case "hmac":
		if _, err := hex.DecodeString(kc.Mac); err != nil || len(kc.Mac) != 64 {
			return nil, withCode(codeCorrupt, "%s: mac is not a hex HMAC-SHA256", path)
		}
	default:
		return nil, withCode(codeCorrupt, "%s: unknown mode %q", path, kc.Mode)
	}
	return &kc, nil
}

// checkKey compares the sidecar with the key the caller gave: a plain
// file opened with a key, or a keyed one with another key, is
// KEY_MISMATCH; a keyed one without a key is KEY_MISSING (retryable: on
// iOS before the first unlock the key is not readable yet).
func (kc *keycheck) checkKey(key []byte) error {
	switch {
	case kc.Mode == "plain" && key != nil:
		return withCode(codeKeyMismatch, "the local index was written without a key, and a key was given")
	case kc.Mode == "hmac" && key == nil:
		return withCode(codeKeyMissing, "the local index was written with a key, and none was given")
	case kc.Mode == "hmac":
		mac, err := keycheckMac(key, kc.FileId)
		if err != nil {
			return err
		}
		if !hmac.Equal([]byte(mac), []byte(kc.Mac)) {
			return withCode(codeKeyMismatch, "the local index was written with another key")
		}
	}
	return nil
}
