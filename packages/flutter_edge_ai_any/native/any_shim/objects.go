package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/anyproto/any-store/v2/anyenc"
	"github.com/anyproto/any-sync-sdk/space"

	editor "anyshim/third_party/any_editor"
)

// The document type, created in a space at first use. Its XKey is what
// identifies it; the display name is what `any` shows.
const (
	docTypeXKey   = "flutter_edge_ai.rag_document"
	docTypeName   = "RAG Document"
	metaPropXKey  = "meta"
	sourcePropKey = "source"
)

type docTypeProps struct {
	meta, source string // the property ids new writes are keyed by
	// Every id of each property on the type, sorted. Two devices that
	// complete one half-synced type at once each add their own; once both
	// sets sync, values may sit under either, so writes go to all of them
	// and reads take the first that is set.
	allMeta, allSource []string
}

func (p *docTypeProps) add(xkey, id string) {
	switch xkey {
	case metaPropXKey:
		p.allMeta = append(p.allMeta, id)
	case sourcePropKey:
		p.allSource = append(p.allSource, id)
	}
}

func (p *docTypeProps) settle() {
	sort.Strings(p.allMeta)
	sort.Strings(p.allSource)
	p.meta, p.source = "", ""
	if len(p.allMeta) > 0 {
		p.meta = p.allMeta[0]
	}
	if len(p.allSource) > 0 {
		p.source = p.allSource[0]
	}
}

// writeProps keys v under every id of each property.
func (p docTypeProps) writeProps(meta, source string) map[string]any {
	m := map[string]any{}
	for _, id := range p.allMeta {
		m[id] = meta
	}
	for _, id := range p.allSource {
		m[id] = source
	}
	return m
}

// written reports whether a put has ever set any of ids on row (a put
// always writes meta, "" when it has none).
func written(row *anyenc.Value, typeId string, ids []string) bool {
	for _, id := range ids {
		if row.Get(typeId, id) != nil {
			return true
		}
	}
	return false
}

// first returns the first of ids set on row as a non-empty string.
func first(row *anyenc.Value, typeId string, ids []string) any {
	for _, id := range ids {
		// "" is what a put without the value writes: not set.
		if v := strOrNil(row.Get(typeId, id)); v != nil && v != "" {
			return v
		}
	}
	return nil
}

// docTypeCache holds the space's document types. Two devices that write
// their first document before they have synced each create one, so a
// space can hold several types with our XKey. All of them are read;
// new objects get the one with the smallest id, which every device
// agrees on once the types have synced.
type docTypeCache struct {
	types   map[string]docTypeProps
	primary string
}

func (a *account) loadDocTypes(sp space.Space, create bool) (*docTypeCache, error) {
	a.docMu.Lock()
	defer a.docMu.Unlock()
	if c, ok := a.docTypes[sp.Id()]; ok && (!create || len(c.types) > 0) {
		return c, nil
	}
	list, err := sp.Types().List(a.ctx)
	if err != nil {
		return nil, err
	}
	c := &docTypeCache{types: map[string]docTypeProps{}}
	var ids, incomplete []string
	for _, t := range list {
		if t.XKey != docTypeXKey {
			continue
		}
		props, err := sp.Types().Properties(a.ctx, t.Id)
		if err != nil {
			return nil, err
		}
		p := propsByXKey(props)
		if p.meta == "" || p.source == "" {
			// Its property definitions have not synced here yet, or the
			// device that created it stopped halfway.
			incomplete = append(incomplete, t.Id)
			continue
		}
		c.types[t.Id] = p
		ids = append(ids, t.Id)
	}
	if len(ids) == 0 {
		if !create {
			return c, nil
		}
		var id string
		var p docTypeProps
		if len(incomplete) > 0 {
			// Complete the existing type rather than add a second one, and
			// rather than wait: a creator that crashed halfway never
			// finishes it. If its own definitions were only still syncing,
			// the type ends up with two of a property; every device then
			// writes the one with the smaller id (propsByXKey).
			sort.Strings(incomplete)
			id = incomplete[0]
			if p, err = completeDocType(a, sp, id); err != nil {
				return nil, err
			}
		} else if id, p, err = createDocType(a, sp); err != nil {
			return nil, err
		}
		c.types[id] = p
		ids = append(ids, id)
	}
	sort.Strings(ids)
	c.primary = ids[0]
	a.docTypes[sp.Id()] = c
	return c, nil
}

func createDocType(a *account, sp space.Space) (_ string, p docTypeProps, err error) {
	id, err := sp.Types().Create(a.ctx, space.TypeCreateParams{
		Name: docTypeName, XKey: docTypeXKey,
		Description: "A document flutter_edge_ai indexes on each device",
	})
	if err != nil {
		return "", p, fmt.Errorf("create document type: %w", err)
	}
	// A type left without its properties would read as "not synced yet"
	// forever and block every later put; remove it instead.
	defer func() {
		if err != nil {
			ctx, cancel := cleanupCtx()
			defer cancel()
			if derr := sp.Types().Delete(ctx, id); derr != nil {
				err = fmt.Errorf("%w (and the half-created document type %s could not be deleted: %v)", err, id, derr)
			}
		}
	}()
	metaId, err := sp.Types().AddProperty(a.ctx, id, space.PropertyDraft{Name: "Metadata", XKey: metaPropXKey, Kind: space.PropertyKindString})
	if err != nil {
		return "", p, fmt.Errorf("document type: %w", err)
	}
	sourceId, err := sp.Types().AddProperty(a.ctx, id, space.PropertyDraft{Name: "Source", XKey: sourcePropKey, Kind: space.PropertyKindString})
	if err != nil {
		return "", p, fmt.Errorf("document type: %w", err)
	}
	p.add(metaPropXKey, metaId)
	p.add(sourcePropKey, sourceId)
	p.settle()
	if _, err = sp.Types().AddPart(a.ctx, id, space.PartDraft{Key: "body", Name: "Body",
		UI: map[string]any{"type": "document"}, Datasets: []space.DatasetDraft{{Module: editor.Module}}}); err != nil {
		return "", p, fmt.Errorf("document type body: %w", err)
	}
	return id, p, nil
}

// propsByXKey picks the document properties of a type; with two of one
// XKey (see loadDocTypes), the smaller id, which every device agrees on.
func propsByXKey(props []space.PropertyDef) docTypeProps {
	var p docTypeProps
	for _, pd := range props {
		p.add(pd.XKey, pd.Id)
	}
	p.settle()
	return p
}

// completeDocType adds what a document type lacks: its two properties and
// its body part.
func completeDocType(a *account, sp space.Space, id string) (docTypeProps, error) {
	props, err := sp.Types().Properties(a.ctx, id)
	if err != nil {
		return docTypeProps{}, err
	}
	p := propsByXKey(props)
	if p.meta == "" {
		mid, err := sp.Types().AddProperty(a.ctx, id, space.PropertyDraft{Name: "Metadata", XKey: metaPropXKey, Kind: space.PropertyKindString})
		if err != nil {
			return p, fmt.Errorf("complete document type: %w", err)
		}
		p.add(metaPropXKey, mid)
	}
	if p.source == "" {
		sid, err := sp.Types().AddProperty(a.ctx, id, space.PropertyDraft{Name: "Source", XKey: sourcePropKey, Kind: space.PropertyKindString})
		if err != nil {
			return p, fmt.Errorf("complete document type: %w", err)
		}
		p.add(sourcePropKey, sid)
	}
	p.settle()
	parts, err := sp.Types().Parts(a.ctx, id)
	if err != nil {
		return p, err
	}
	hasBody := false
	for _, pt := range parts {
		hasBody = hasBody || pt.Key == "body"
	}
	if !hasBody {
		if _, err = sp.Types().AddPart(a.ctx, id, space.PartDraft{Key: "body", Name: "Body",
			UI: map[string]any{"type": "document"}, Datasets: []space.DatasetDraft{{Module: editor.Module}}}); err != nil {
			return p, fmt.Errorf("complete document type body: %w", err)
		}
	}
	return p, nil
}

// propsFor returns the property ids of the document type typeId, reloading
// the cache once for a type that synced in after it was filled.
func (a *account) propsFor(sp space.Space, typeId string) (docTypeProps, bool, error) {
	c, err := a.loadDocTypes(sp, false)
	if err != nil {
		return docTypeProps{}, false, err
	}
	if p, ok := c.types[typeId]; ok {
		return p, true, nil
	}
	a.docMu.Lock()
	delete(a.docTypes, sp.Id())
	a.docMu.Unlock()
	if c, err = a.loadDocTypes(sp, false); err != nil {
		return docTypeProps{}, false, err
	}
	p, ok := c.types[typeId]
	return p, ok, nil
}

type docIn struct {
	Id     string          `json:"id"`
	Seed   string          `json:"seed"`
	Name   string          `json:"name"`
	Text   string          `json:"text"`
	Source string          `json:"source"`
	Meta   json.RawMessage `json:"meta"`
}

func metaText(raw json.RawMessage) (string, error) {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 || string(t) == "null" {
		return "", nil
	}
	if t[0] != '{' {
		return "", invalid("meta must be a JSON object")
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, t); err != nil {
		return "", invalid("meta: %v", err)
	}
	return buf.String(), nil
}

func (a *account) objectPut(spaceId string, d docIn) (_ map[string]any, err error) {
	if d.Id != "" && d.Seed != "" {
		return nil, invalid("give id or seed, not both")
	}
	meta, err := metaText(d.Meta)
	if err != nil {
		return nil, err
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	c, err := a.loadDocTypes(sp, true)
	if err != nil {
		return nil, err
	}
	props := func(p docTypeProps) map[string]any {
		return p.writeProps(meta, d.Source)
	}
	objId, created := d.Id, false
	switch {
	case d.Id == "" && d.Seed == "":
		objId, err = sp.Objects().Create(a.ctx, space.CreateObjectOpts{Type: c.primary,
			InitialProperties: map[string]map[string]any{c.primary: props(c.types[c.primary])}})
		if err != nil {
			return nil, fmt.Errorf("create: %w", err)
		}
		created = true
		// A created object is deletable: one that fails half-written is
		// removed rather than left nameless in the synced space.
		defer func() {
			if err != nil {
				ctx, cancel := cleanupCtx()
				defer cancel()
				if derr := sp.Objects().Delete(ctx, objId); derr != nil {
					err = fmt.Errorf("%w (and the half-written object %s could not be deleted: %v)", err, objId, derr)
				}
			}
		}()
	default:
		if d.Seed != "" {
			id, err := sp.Objects().Derive(a.ctx, space.DeriveObjectOpts{Seed: []byte(d.Seed), Type: c.primary})
			if err != nil {
				return nil, fmt.Errorf("derive: %w", err)
			}
			objId = id
		}
		row, err := sp.Objects().Get(a.ctx, objId)
		if err != nil {
			return nil, err
		}
		typeId := string(row.GetStringBytes("any", "type"))
		if typeId == "" {
			// The tree is here, its row not yet (still syncing).
			return nil, withCode(codeNotFound, "object %s has not finished syncing here; retry", objId)
		}
		p, ok, err := a.propsFor(sp, typeId)
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, invalid("object %s has type %q, not a document type", objId, typeId)
		}
		// Derive does not say whether it materialized the object; a
		// document always has its meta set, so an unset one is new.
		created = d.Seed != "" && !written(row, typeId, p.allMeta)
		if _, err = sp.Properties().Set(a.ctx, objId, typeId, props(p)); err != nil {
			return nil, fmt.Errorf("set properties: %w", err)
		}
	}
	if _, err = sp.Properties().Set(a.ctx, objId, "any", map[string]any{"name": d.Name}); err != nil {
		return nil, fmt.Errorf("set name: %w", err)
	}
	if err = writeBody(a, sp, objId, d.Text); err != nil {
		return nil, fmt.Errorf("body: %w", err)
	}
	return map[string]any{"id": objId, "created": created}, nil
}

// writeBody replaces the object's editor body with one paragraph per
// non-empty line.
func writeBody(a *account, sp space.Space, objId, text string) error {
	old, err := sp.Query(objId, editor.Dataset).All(a.ctx)
	if err != nil {
		return err
	}
	var recs []space.RecordModify
	for _, o := range old {
		recs = append(recs, space.RecordModify{Id: string(o.GetStringBytes("id")), Ops: []space.Op{{Type: space.OpDelete}}})
	}
	pos := 0
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		pos++
		recs = append(recs, space.RecordModify{Upsert: true, Ops: []space.Op{{Type: space.OpSet, Value: map[string]any{
			editor.FieldType: editor.TypeParagraph,
			editor.FieldText: line,
			editor.FieldNav:  map[string]any{editor.NavParentId: "", editor.NavPos: fmt.Sprintf("%06d", pos)},
		}}}})
	}
	if len(recs) == 0 {
		return nil
	}
	_, err = sp.Modify(a.ctx, space.ModifyBatch{ObjectId: objId, Dataset: editor.Dataset, Records: recs})
	return err
}

func strOrNil(v *anyenc.Value) any {
	if v == nil || v.Type() != anyenc.TypeString {
		return nil
	}
	return string(v.GetStringBytes())
}

func (a *account) objectGet(spaceId, objId string) (map[string]any, error) {
	if objId == "" {
		return nil, invalid("object id is empty")
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	row, err := sp.Objects().Get(a.ctx, objId)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, withCode(codeNotFound, "object %s is not here", objId)
	}
	blocks, err := sp.Query(objId, editor.Dataset).Sort(editor.FieldNav + "." + editor.NavPos).All(a.ctx)
	if err != nil {
		return nil, err
	}
	lines := make([]string, 0, len(blocks))
	for _, b := range blocks {
		lines = append(lines, string(b.GetStringBytes(editor.FieldText)))
	}
	typeId := string(row.GetStringBytes("any", "type"))
	out := map[string]any{
		"id":         objId,
		"type":       typeId,
		"isDocument": false,
		"name":       string(row.GetStringBytes("any", "name")),
		"text":       strings.Join(lines, "\n"),
		"source":     nil,
		"meta":       nil,
		"row":        goValue(row),
	}
	if p, ok, err := a.propsFor(sp, typeId); err != nil {
		return nil, err
	} else if ok {
		out["isDocument"] = true
		if first(row, typeId, p.allMeta) == nil {
			// Possibly under a property id that synced in after the
			// cache was filled: look again once.
			a.docMu.Lock()
			delete(a.docTypes, sp.Id())
			a.docMu.Unlock()
			if p2, ok2, err := a.propsFor(sp, typeId); err == nil && ok2 {
				p = p2
			}
		}
		out["meta"] = first(row, typeId, p.allMeta)
		out["source"] = first(row, typeId, p.allSource)
		if out["meta"] == "" {
			out["meta"] = nil
		}
	}
	return out, nil
}

func (a *account) objectQuery(spaceId, filter string, limit int) ([]any, error) {
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	q := sp.QueryObjects()
	if f := strings.TrimSpace(filter); f != "" && f != "{}" {
		var m map[string]any
		if err := json.Unmarshal([]byte(f), &m); err != nil || m == nil {
			return nil, invalid("filter must be a JSON object: %s", f)
		}
		q = q.Filter(m)
	}
	if limit > 0 {
		q = q.Limit(limit)
	}
	rows, err := q.All(a.ctx)
	if err != nil {
		return nil, err
	}
	out := make([]any, 0, len(rows))
	for _, r := range rows {
		out = append(out, goValue(r))
	}
	return out, nil
}

// ---------------------------------------------------------------- exports

//export any_shim_object_put
func any_shim_object_put(h C.uint64_t, spaceID, docJSON *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			var d docIn
			if err := decodeStrict(goStr(docJSON), &d); err != nil {
				return err
			}
			r, err := a.objectPut(goStr(spaceID), d)
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_object_get
func any_shim_object_get(h C.uint64_t, spaceID, objectID *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.objectGet(goStr(spaceID), goStr(objectID))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_object_delete
func any_shim_object_delete(h C.uint64_t, spaceID, objectID *C.char, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			id := goStr(objectID)
			if id == "" {
				return invalid("object id is empty")
			}
			sp, err := a.space(goStr(spaceID))
			if err != nil {
				return err
			}
			return sp.Objects().Delete(a.ctx, id)
		})
	})
}

//export any_shim_object_query
func any_shim_object_query(h C.uint64_t, spaceID, filterJSON *C.char, limit C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.objectQuery(goStr(spaceID), goStr(filterJSON), int(limit))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}
