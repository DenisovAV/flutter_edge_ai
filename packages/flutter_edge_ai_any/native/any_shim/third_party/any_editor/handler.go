package editor

import (
	"errors"
	"fmt"

	anystore "github.com/anyproto/any-store/v2"
	"github.com/anyproto/any-store/v2/anyenc"

	"github.com/anyproto/any-sync-sdk/handler"
)

// Indexes declares the any-store indexes ensured on each object's
// `editor_blocks` collection. Children listings and `MaxPos` both
// filter by `nav.parentId` and sort by `nav.pos` (ascending for tree
// walks, descending for tail-append), so a compound
// `(nav.parentId, nav.pos)` index keeps both off a full sweep. Every
// block carries `nav.parentId` and `nav.pos` (required at create),
// so the index is dense — no Sparse.
func (blocksHandler) Indexes() []anystore.IndexInfo {
	return []anystore.IndexInfo{
		{Name: "idx_nav", Fields: []string{"nav.parentId", "nav.pos"}},
	}
}

// BeforeCreate validates a block-record creation payload. Expected
// shape is exactly one multi-field $set op (empty Path, object
// payload). Required: type (non-empty string), nav.parentId (string),
// nav.pos (non-empty string). Optional: style (object), text (string).
//
// Unknown root keys reject the whole record (defense against client
// bugs / unexpected schema additions sneaking in). Style sub-keys
// aren't constrained — the handler only enforces that `style` is an
// object when present.
func (blocksHandler) BeforeCreate(_ *handler.ChangeCtx, rec *handler.RecordChange, _ *handler.Sink) error {
	if len(rec.Ops) != 1 {
		return rejectCreate("expected exactly one multi-field $set op")
	}
	op := &rec.Ops[0]
	if op.Type != handler.OpSet || len(op.Path) != 0 {
		return rejectCreate("expected multi-field $set with empty path")
	}
	if op.Payload == nil || op.Payload.Type() != anyenc.TypeObject {
		return rejectCreate("payload must be a JSON object")
	}
	return validateCreatePayload(op.Payload)
}

// BeforeModify gates per-op edits. Path allow-list:
//
//   - type                     — $set (string, non-empty)
//   - style                    — $set (object, multi-field replace)
//   - style.<key>              — $set / $unset (any scalar)
//   - text                     — $set / $unset (string)
//   - nav                      — $set (object, multi-field replace)
//   - nav.parentId             — $set (string)
//   - nav.pos                  — $set (non-empty string)
//
// Anything else (including writes to id, _ver, _co, _deletedAt) drops
// the op. Other ops in the same RecordChange still apply — per-op
// rejection is the SDK's contract here.
func (blocksHandler) BeforeModify(_ *handler.ChangeCtx, _ *handler.RecordChange, op *handler.Op, _ *handler.Sink) error {
	switch op.Type {
	case handler.OpSet:
		return validateSet(op)
	case handler.OpUnset:
		return validateUnset(op)
	default:
		return rejectOp("op_not_supported: " + string(op.Type))
	}
}

// BeforeDelete accepts any tombstone. Block authorship isn't tracked
// (unlike chat) — anyone with write access to the object can delete
// any block. Future versions may add per-block ownership.
func (blocksHandler) BeforeDelete(_ *handler.ChangeCtx, _ *handler.RecordChange, _ *handler.Sink) error {
	return nil
}

// --- helpers ---------------------------------------------------------------

func validateCreatePayload(payload *anyenc.Value) error {
	obj, err := payload.Object()
	if err != nil {
		return rejectCreate("payload must be a JSON object")
	}

	var (
		visitErr error
		hasType  bool
	)
	obj.Visit(func(rawKey []byte, v *anyenc.Value) {
		if visitErr != nil {
			return
		}
		key := string(rawKey)
		switch key {
		case FieldType:
			hasType = true
			if v.Type() != anyenc.TypeString {
				visitErr = rejectCreate("type must be a string")
				return
			}
			t := v.GetStringBytes()
			if len(t) == 0 {
				visitErr = rejectCreate("type required")
				return
			}
			if len(t) > MaxTypeBytes {
				visitErr = rejectCreate(fmt.Sprintf("type too long (%d > %d bytes)", len(t), MaxTypeBytes))
				return
			}
		case FieldStyle:
			if v.Type() != anyenc.TypeObject {
				visitErr = rejectCreate("style must be an object")
				return
			}
		case FieldText:
			if v.Type() != anyenc.TypeString {
				visitErr = rejectCreate("text must be a string")
				return
			}
			if len(v.GetStringBytes()) > MaxTextBytes {
				visitErr = rejectCreate(fmt.Sprintf("text too long (%d > %d bytes)", len(v.GetStringBytes()), MaxTextBytes))
				return
			}
		case FieldNav:
			if visitErr = validateNavObject(v); visitErr != nil {
				return
			}
		default:
			visitErr = rejectCreate("field_not_allowed: " + key)
			return
		}
	})
	if visitErr != nil {
		return visitErr
	}
	if !hasType {
		return rejectCreate("type required")
	}
	return nil
}

// validateNavObject checks the structure of the nav sub-object. Nav
// is required on create (BeforeCreate calls this) but parentId may be
// empty (root) and we don't enforce pos's lexid alphabet — that's the
// allocator's job. We just enforce types + length caps.
func validateNavObject(v *anyenc.Value) error {
	if v.Type() != anyenc.TypeObject {
		return rejectCreate("nav must be an object")
	}
	obj, _ := v.Object()
	if obj == nil {
		return rejectCreate("nav must be an object")
	}
	var (
		err    error
		hasPos bool
	)
	obj.Visit(func(rawKey []byte, val *anyenc.Value) {
		if err != nil {
			return
		}
		key := string(rawKey)
		switch key {
		case NavParentId:
			if val.Type() != anyenc.TypeString {
				err = rejectCreate("nav.parentId must be a string")
				return
			}
			if len(val.GetStringBytes()) > MaxParentIdBytes {
				err = rejectCreate("nav.parentId too long")
				return
			}
		case NavPos:
			hasPos = true
			if val.Type() != anyenc.TypeString {
				err = rejectCreate("nav.pos must be a string")
				return
			}
			pos := val.GetStringBytes()
			if len(pos) == 0 {
				err = rejectCreate("nav.pos required")
				return
			}
			if len(pos) > MaxPosBytes {
				err = rejectCreate("nav.pos too long")
				return
			}
		default:
			err = rejectCreate("nav field_not_allowed: " + key)
			return
		}
	})
	if err != nil {
		return err
	}
	if !hasPos {
		return rejectCreate("nav.pos required")
	}
	return nil
}

// validateSet runs the field allow-list and per-field type checks for
// $set ops applied post-creation.
func validateSet(op *handler.Op) error {
	switch len(op.Path) {
	case 1:
		switch op.Path[0] {
		case FieldType:
			if op.Payload == nil || op.Payload.Type() != anyenc.TypeString {
				return rejectOp("type must be a string")
			}
			t := op.Payload.GetStringBytes()
			if len(t) == 0 {
				return rejectOp("type required")
			}
			if len(t) > MaxTypeBytes {
				return rejectOp("type too long")
			}
			return nil
		case FieldText:
			if op.Payload == nil {
				return rejectOp("text payload missing")
			}
			if op.Payload.Type() != anyenc.TypeString {
				return rejectOp("text must be a string")
			}
			if len(op.Payload.GetStringBytes()) > MaxTextBytes {
				return rejectOp("text too long")
			}
			return nil
		case FieldStyle:
			if op.Payload == nil || op.Payload.Type() != anyenc.TypeObject {
				return rejectOp("style must be an object")
			}
			return nil
		case FieldNav:
			if op.Payload == nil {
				return rejectOp("nav payload missing")
			}
			return validateNavObject(op.Payload)
		default:
			return rejectOp("field_not_modifiable: " + pathString(op.Path))
		}
	case 2:
		switch op.Path[0] {
		case FieldStyle:
			// Sub-key — allow any scalar / object. Style is open-ended.
			return nil
		case FieldNav:
			switch op.Path[1] {
			case NavParentId:
				if op.Payload == nil || op.Payload.Type() != anyenc.TypeString {
					return rejectOp("nav.parentId must be a string")
				}
				return nil
			case NavPos:
				if op.Payload == nil || op.Payload.Type() != anyenc.TypeString {
					return rejectOp("nav.pos must be a string")
				}
				if len(op.Payload.GetStringBytes()) == 0 {
					return rejectOp("nav.pos required")
				}
				return nil
			default:
				return rejectOp("field_not_modifiable: " + pathString(op.Path))
			}
		default:
			return rejectOp("field_not_modifiable: " + pathString(op.Path))
		}
	default:
		return rejectOp("field_not_modifiable: " + pathString(op.Path))
	}
}

// validateUnset enforces the allow-list for $unset ops. Required
// fields (type, nav.pos) cannot be unset; optional ones can.
func validateUnset(op *handler.Op) error {
	switch len(op.Path) {
	case 1:
		switch op.Path[0] {
		case FieldText, FieldStyle:
			return nil
		case FieldType, FieldNav:
			return rejectOp("cannot unset required field: " + pathString(op.Path))
		default:
			return rejectOp("field_not_modifiable: " + pathString(op.Path))
		}
	case 2:
		switch op.Path[0] {
		case FieldStyle:
			return nil
		case FieldNav:
			if op.Path[1] == NavParentId {
				return rejectOp("cannot unset nav.parentId; $set to empty string for root")
			}
			if op.Path[1] == NavPos {
				return rejectOp("cannot unset nav.pos")
			}
			return rejectOp("field_not_modifiable: " + pathString(op.Path))
		default:
			return rejectOp("field_not_modifiable: " + pathString(op.Path))
		}
	default:
		return rejectOp("field_not_modifiable: " + pathString(op.Path))
	}
}

func pathString(path []string) string {
	if len(path) == 0 {
		return "<root>"
	}
	out := path[0]
	for _, seg := range path[1:] {
		out += "." + seg
	}
	return out
}

func rejectCreate(msg string) error {
	return errors.Join(handler.ErrValidation, fmt.Errorf("blocks.create: %s", msg))
}

func rejectOp(msg string) error {
	return errors.Join(handler.ErrValidation, fmt.Errorf("blocks: %s", msg))
}
