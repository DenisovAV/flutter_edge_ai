package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/anyproto/any-store/v2/anyenc"
	"github.com/anyproto/any-sync-sdk/space"
	"github.com/anyproto/any-sync/commonspace/object/tree/objecttree"

	editor "anyshim/third_party/any_editor"
)

// leafRe is the shape of a leaf key under an object-kind property: the
// SDK splits paths on '.', so a leaf is a hash or a hash-type pair, never
// a raw name.
var leafRe = regexp.MustCompile(`^[0-9a-z-]+$`)

// objectsDataset is the SDK's per-space objects collection: one record
// per object, its property values under <typeId>.<propId>.
const objectsDataset = "objects"

// jsonValue decodes one JSON value into the Go values the SDK converts
// (Op.Value): integers stay integers (int64) instead of float64.
func jsonValue(raw json.RawMessage) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return numbers(v), nil
}

func numbers(v any) any {
	switch t := v.(type) {
	case json.Number:
		if i, err := t.Int64(); err == nil {
			return i
		}
		f, _ := t.Float64()
		return f
	case map[string]any:
		for k, x := range t {
			t[k] = numbers(x)
		}
		return t
	case []any:
		for i, x := range t {
			t[i] = numbers(x)
		}
		return t
	}
	return v
}

// rejectionsErr turns ModifyResult.Rejections into an error: the change
// committed but these ops did not land, so the call is not OK. A
// rejection of a deleted record is ANY_SHIM_ERR_DELETED.
func rejectionsErr(rs []space.OpRejection) error {
	if len(rs) == 0 {
		return nil
	}
	var reasons []string
	deleted := false
	for _, r := range rs {
		reasons = append(reasons, fmt.Sprintf("record %q op %d: %s", r.RecordId, r.OpIndex, r.Reason))
		deleted = deleted || errors.Is(r.ReasonErr, space.ErrRecordDeleted)
	}
	code := codeRefused
	if deleted {
		code = codeDeleted
	}
	return withCode(code, "the change committed, but %d op(s) were rejected: %s", len(rs), strings.Join(reasons, "; "))
}

// objectState reads what Get says of an object: "ok" with its row,
// "missing" (unknown here, or its tree is here without a typed row yet),
// or "deleted".
func objectState(ctx context.Context, sp space.Space, id string) (string, *anyenc.Value, error) {
	row, err := sp.Objects().Get(ctx, id)
	switch {
	case err == nil:
		if len(row.GetStringBytes("any", "type")) == 0 {
			return "missing", row, nil
		}
		return "ok", row, nil
	case errors.Is(err, space.ErrObjectDeleted):
		return "deleted", nil, nil
	case errors.Is(err, space.ErrNotFound), errors.Is(err, space.ErrObjectNotFound):
		return "missing", nil, nil
	}
	return "", nil, err
}

// notFoundOrDeleted tells the two apart for a write the SDK refused with
// ErrObjectNotFound, which it raises for both.
func notFoundOrDeleted(ctx context.Context, sp space.Space, id string, err error) error {
	if !errors.Is(err, space.ErrObjectNotFound) && !errors.Is(err, space.ErrNotFound) {
		return err
	}
	if st, _, gerr := objectState(ctx, sp, id); gerr == nil && st == "deleted" {
		return withCode(codeDeleted, "object %s was deleted: %v", id, err)
	}
	return withCode(codeNotFound, "object %s is not here: %v", id, err)
}

// typeProps maps XKey -> property definition for a type. Two of one
// XKey (AddProperty on two devices) resolve to the smaller id, which
// every device picks. synced reports whether the type has any
// definitions here at all.
func typeProps(ctx context.Context, sp space.Space, typeId string) (map[string]space.PropertyDef, bool, error) {
	// The SDK answers an unknown or not yet synced type with an empty
	// list; an error is a real failure (I/O, a closed account) and is
	// reported as such, never as "not synced".
	props, err := sp.Types().Properties(ctx, typeId)
	if err != nil {
		return nil, false, fmt.Errorf("properties of type %s: %w", typeId, err)
	}
	sort.Slice(props, func(i, j int) bool { return props[i].Id < props[j].Id })
	out := map[string]space.PropertyDef{}
	for _, p := range props {
		if p.XKey == "" {
			continue
		}
		if _, ok := out[p.XKey]; !ok {
			out[p.XKey] = p
		}
	}
	return out, len(props) > 0, nil
}

// declaredByOurBundle reports whether typeId is the derived root of one of
// our bundles and that bundle declares xkey: such an xkey missing from a
// synced type was removed (RemoveProperty), not "not ours".
func declaredByOurBundle(ctx context.Context, sp space.Space, typeId, xkey string) bool {
	for _, req := range []space.EnsureBundleRequest{ragLocationBundle(), ragDocumentBundle()} {
		root, err := sp.Bundles().DerivedRootId(ctx, req.Id)
		if err != nil || root != typeId {
			continue
		}
		for _, p := range req.Properties {
			if p.XKey == xkey {
				return true
			}
		}
	}
	return false
}

// ------------------------------------------------------------ object_patch

type patchTarget struct {
	Id     string `json:"id"`
	Create *struct {
		Type string `json:"type"`
	} `json:"create"`
	Derive *struct {
		Seed string `json:"seed"`
		Type string `json:"type"`
	} `json:"derive"`
}

type patchOp struct {
	XKey  string          `json:"xkey"`
	Leaf  *string         `json:"leaf"`
	Value json.RawMessage `json:"value"`
}

type resolvedOp struct {
	propId string
	leaf   string
	value  any
	xkey   string
}

func (o resolvedOp) path(typeId string) string {
	p := typeId + "." + o.propId
	if o.leaf != "" {
		p += "." + o.leaf
	}
	return p
}

func parsePatch(targetJSON, opsJSON string) (patchTarget, []patchOp, error) {
	var t patchTarget
	if err := decodeStrict(targetJSON, &t); err != nil {
		return t, nil, invalid("target: %v", err)
	}
	n := 0
	if t.Id != "" {
		n++
	}
	if t.Create != nil {
		n++
		if t.Create.Type == "" {
			return t, nil, invalid("target create needs a type")
		}
	}
	if t.Derive != nil {
		n++
		if t.Derive.Type == "" || t.Derive.Seed == "" {
			return t, nil, invalid("target derive needs a seed and a type")
		}
	}
	if n != 1 {
		return t, nil, invalid("target must be exactly one of id, create, derive")
	}
	var ops []patchOp
	if strings.TrimSpace(opsJSON) != "" {
		if err := decodeStrict(opsJSON, &ops); err != nil {
			return t, nil, invalid("ops: %v", err)
		}
	}
	for i, o := range ops {
		if o.XKey == "" {
			return t, nil, invalid("ops[%d]: xkey is empty", i)
		}
		if o.Leaf != nil && !leafRe.MatchString(*o.Leaf) {
			return t, nil, invalid("ops[%d]: leaf %q is not [0-9a-z-]+", i, *o.Leaf)
		}
		if len(bytes.TrimSpace(o.Value)) == 0 {
			return t, nil, invalid("ops[%d]: value is missing", i)
		}
	}
	return t, ops, nil
}

// resolveOps maps each op's XKey to the type's property id. An XKey the
// type does not declare is NOT_FOUND while the type has no definitions
// here (they have not synced), INVALID_ARGUMENT otherwise.
func resolveOps(ctx context.Context, sp space.Space, typeId string, ops []patchOp) ([]resolvedOp, error) {
	if len(ops) == 0 {
		return nil, nil
	}
	props, synced, err := typeProps(ctx, sp, typeId)
	if err != nil {
		return nil, err
	}
	out := make([]resolvedOp, 0, len(ops))
	for i, o := range ops {
		p, ok := props[o.XKey]
		if !ok {
			if !synced {
				return nil, withCode(codeNotFound, "the definitions of type %s have not synced here (property %q)", typeId, o.XKey)
			}
			if declaredByOurBundle(ctx, sp, typeId, o.XKey) {
				return nil, withCode(codeRefused, "property %q of type %s was declared and has been removed", o.XKey, typeId)
			}
			return nil, invalid("type %s declares no property %q", typeId, o.XKey)
		}
		v, err := jsonValue(o.Value)
		if err != nil {
			return nil, invalid("ops[%d].value: %v", i, err)
		}
		r := resolvedOp{propId: p.Id, value: v, xkey: o.XKey}
		if o.Leaf != nil {
			if p.Kind != space.PropertyKindObject {
				return nil, invalid("ops[%d]: property %q is not object-kind, it has no leaves", i, o.XKey)
			}
			r.leaf = *o.Leaf
		}
		out = append(out, r)
	}
	return out, nil
}

// initialProperties folds the ops into Create's InitialProperties: a
// leaf becomes a key of the property's object value.
func initialProperties(typeId string, ops []resolvedOp) (map[string]map[string]any, error) {
	vals := map[string]any{}
	for _, o := range ops {
		if o.leaf == "" {
			vals[o.propId] = o.value
			continue
		}
		m, ok := vals[o.propId].(map[string]any)
		if !ok {
			if _, set := vals[o.propId]; set {
				return nil, invalid("property %q is set whole and by leaf in one create", o.xkey)
			}
			m = map[string]any{}
			vals[o.propId] = m
		}
		m[o.leaf] = o.value
	}
	return map[string]map[string]any{typeId: vals}, nil
}

func (a *account) objectPatch(spaceId, targetJSON, opsJSON string) (_ map[string]any, err error) {
	t, ops, err := parsePatch(targetJSON, opsJSON)
	if err != nil {
		return nil, err
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	ctx := a.ctx
	switch {
	case t.Create != nil:
		typeId := t.Create.Type
		res, err := resolveOps(ctx, sp, typeId, ops)
		if err != nil {
			return nil, err
		}
		ip, err := initialProperties(typeId, res)
		if err != nil {
			return nil, err
		}
		// One change: the object's first change carries the values.
		id, err := sp.Objects().Create(ctx, space.CreateObjectOpts{Type: typeId, InitialProperties: ip})
		if err != nil {
			return nil, writeErr(err)
		}
		// Create ignores ops the apply layer rejected; a value that did
		// not land makes a half-made object, which is deleted again.
		if err := checkLandedHook(ctx, sp, id, typeId, res); err != nil {
			dctx, cancel := cleanupCtx()
			defer cancel()
			if derr := sp.Objects().Delete(dctx, id); derr != nil {
				return nil, fmt.Errorf("%w (and the half-made object %s could not be deleted: %v)", err, id, derr)
			}
			return nil, err
		}
		return map[string]any{"id": id, "created": true}, nil

	case t.Derive != nil:
		typeId := t.Derive.Type
		res, err := resolveOps(ctx, sp, typeId, ops)
		if err != nil {
			return nil, err
		}
		id, err := sp.Objects().Derive(ctx, space.DeriveObjectOpts{Seed: []byte(t.Derive.Seed), Type: typeId})
		if err != nil {
			return nil, writeErr(err)
		}
		row, err := sp.Objects().Get(ctx, id)
		if err != nil {
			return nil, notFoundOrDeleted(ctx, sp, id, err)
		}
		if got := string(row.GetStringBytes("any", "type")); got != typeId {
			return nil, withCode(codeRefused, "derived object %s has type %q, not %q", id, got, typeId)
		}
		// Derive does not say whether it materialized the object: one
		// without any value of its type is reported as created.
		created := row.Get(typeId) == nil
		if err := modifyObject(ctx, sp, id, typeId, res); err != nil {
			return nil, err
		}
		return map[string]any{"id": id, "created": created}, nil

	default:
		id := t.Id
		st, row, err := objectState(ctx, sp, id)
		if err != nil {
			return nil, err
		}
		switch {
		case st == "deleted":
			return nil, withCode(codeDeleted, "object %s was deleted", id)
		case st == "missing":
			return nil, withCode(codeNotFound, "object %s is not here (yet)", id)
		}
		typeId := string(row.GetStringBytes("any", "type"))
		res, err := resolveOps(ctx, sp, typeId, ops)
		if err != nil {
			return nil, err
		}
		if err := modifyObject(ctx, sp, id, typeId, res); err != nil {
			return nil, err
		}
		return map[string]any{"id": id, "created": false}, nil
	}
}

func modifyObject(ctx context.Context, sp space.Space, id, typeId string, ops []resolvedOp) error {
	if len(ops) == 0 {
		return nil
	}
	sops := make([]space.Op, 0, len(ops))
	for _, o := range ops {
		sops = append(sops, space.Op{Type: space.OpSet, Path: o.path(typeId), Value: o.value})
	}
	r, err := sp.Modify(ctx, space.ModifyBatch{ObjectId: id, Dataset: objectsDataset,
		Records: []space.RecordModify{{Id: id, Upsert: true, Ops: sops}}})
	if err != nil {
		return writeErr(notFoundOrDeleted(ctx, sp, id, err))
	}
	return rejectionsErr(r.Rejections)
}

// checkLandedHook is checkLanded; tests replace it to simulate an
// apply-time rejection, which no declared value of ours produces.
var checkLandedHook = checkLanded

// checkLanded verifies that every value a create wrote is on the row.
func checkLanded(ctx context.Context, sp space.Space, id, typeId string, ops []resolvedOp) error {
	if len(ops) == 0 {
		return nil
	}
	row, err := sp.Objects().Get(ctx, id)
	if err != nil {
		return err
	}
	var missing []string
	for _, o := range ops {
		path := []string{typeId, o.propId}
		if o.leaf != "" {
			path = append(path, o.leaf)
		}
		if row.Get(path...) == nil {
			missing = append(missing, o.xkey)
		}
	}
	if len(missing) > 0 {
		return withCode(codeRefused, "create: the values of %v were rejected", missing)
	}
	return nil
}

// ---------------------------------------------------------- object_set_body

// setBody replaces the object's editor body with one paragraph per
// non-empty line, in one change.
func setBody(ctx context.Context, sp space.Space, objId, text string) error {
	old, err := sp.Query(objId, editor.Dataset).All(ctx)
	if err != nil {
		return notFoundOrDeleted(ctx, sp, objId, err)
	}
	var recs []space.RecordModify
	for _, o := range old {
		recs = append(recs, space.RecordModify{Id: string(o.GetStringBytes("id")), Ops: []space.Op{{Type: space.OpDelete}}})
	}
	pos := 0
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")
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
	r, err := sp.Modify(ctx, space.ModifyBatch{ObjectId: objId, Dataset: editor.Dataset, Records: recs})
	if err != nil {
		return writeErr(notFoundOrDeleted(ctx, sp, objId, err))
	}
	return rejectionsErr(r.Rejections)
}

// --------------------------------------------------------------- object_read

type readRequest struct {
	Ids   []string `json:"ids"`
	Type  string   `json:"type"`
	After string   `json:"after"`
	Limit int      `json:"limit"`
	XKeys []string `json:"xkeys"`
}

const (
	defaultReadLimit = 100
	maxReadLimit     = 1000
)

// readAnchor reads {generation, maxApplySeq} so that both belong to one
// generation: generation, seq, generation, retried until the two
// generation reads agree.
func readAnchor(ctx context.Context, sp space.Space) (map[string]any, error) {
	for i := 0; i < 10; i++ {
		g1, err := sp.Changes().Generation(ctx)
		if err != nil {
			return nil, err
		}
		seq, err := sp.Changes().MaxApplySeq(ctx)
		if err != nil {
			return nil, err
		}
		g2, err := sp.Changes().Generation(ctx)
		if err != nil {
			return nil, err
		}
		if g1 == g2 {
			return map[string]any{"generation": g1, "maxApplySeq": seq}, nil
		}
	}
	return nil, withCode(codeInternal, "the change index generation kept changing while it was read")
}

func (a *account) objectRead(spaceId, reqJSON string) (map[string]any, error) {
	var req readRequest
	if err := decodeStrict(reqJSON, &req); err != nil {
		return nil, err
	}
	byIds := req.Ids != nil
	if byIds == (req.Type != "") {
		return nil, invalid("request needs exactly one of ids and type")
	}
	if byIds && (req.After != "" || req.Limit != 0) {
		return nil, invalid("after and limit go with type, not ids")
	}
	limit := req.Limit
	if limit <= 0 {
		limit = defaultReadLimit
	}
	if limit > maxReadLimit {
		return nil, invalid("limit %d is above %d", limit, maxReadLimit)
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	ctx := a.ctx
	anchor, err := readAnchor(ctx, sp)
	if err != nil {
		return nil, err
	}
	propCache := map[string]map[string]space.PropertyDef{}
	project := func(row *anyenc.Value, typeId string) (map[string]any, error) {
		props, ok := propCache[typeId]
		if !ok {
			p, _, err := typeProps(ctx, sp, typeId)
			if err != nil {
				return nil, err
			}
			props, propCache[typeId] = p, p
		}
		out := map[string]any{}
		for _, x := range req.XKeys {
			out[x] = nil
			if p, ok := props[x]; ok && typeId != "" {
				out[x] = goValue(row.Get(typeId, p.Id))
			}
		}
		return out, nil
	}
	items := []map[string]any{}
	var next any
	if byIds {
		for _, id := range req.Ids {
			if id == "" {
				return nil, invalid("ids holds an empty id")
			}
			st, row, err := objectState(ctx, sp, id)
			if err != nil {
				return nil, err
			}
			it := map[string]any{"id": id, "typeId": nil, "state": st, "props": map[string]any{}}
			if st == "ok" {
				typeId := string(row.GetStringBytes("any", "type"))
				it["typeId"] = typeId
				if it["props"], err = project(row, typeId); err != nil {
					return nil, err
				}
			}
			items = append(items, it)
		}
	} else {
		filter := map[string]any{"any.type": req.Type}
		if req.After != "" {
			filter["id"] = map[string]any{"$gt": req.After}
		}
		rows, err := sp.QueryObjects().Filter(filter).Sort("id").Limit(limit + 1).All(ctx)
		if err != nil {
			return nil, err
		}
		if len(rows) > limit {
			rows = rows[:limit]
			next = string(rows[limit-1].GetStringBytes("id"))
		}
		for _, row := range rows {
			p, err := project(row, req.Type)
			if err != nil {
				return nil, err
			}
			items = append(items, map[string]any{"id": string(row.GetStringBytes("id")),
				"typeId": req.Type, "state": "ok", "props": p})
		}
	}
	return map[string]any{"anchor": anchor, "items": items, "next": next}, nil
}

// ------------------------------------------------- delete, sync state

func (a *account) objectDelete(spaceId, id string) error {
	if id == "" {
		return invalid("object id is empty")
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return err
	}
	// The SDK's own delete of an unknown id fails with an unwrapped
	// any-store message; Get tells the three cases apart first.
	st, _, err := objectState(a.ctx, sp, id)
	if err != nil {
		return err
	}
	switch st {
	case "deleted":
		return nil
	case "missing":
		return withCode(codeNotFound, "object %s is not here", id)
	}
	err = sp.Objects().Delete(a.ctx, id)
	if errors.Is(err, space.ErrObjectDeleted) {
		return nil
	}
	if err != nil {
		return writeErr(err)
	}
	return nil
}

func (a *account) objectSyncState(spaceId, id string) (map[string]any, error) {
	if id == "" {
		return nil, invalid("object id is empty")
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	st := sp.SyncStatus().Object(id)
	return map[string]any{"state": st.State.String()}, nil
}

// ---------------------------------------------------------------- records

type recordIn struct {
	Id       string                     `json:"id"`
	Set      map[string]json.RawMessage `json:"set"`
	AddToSet map[string]json.RawMessage `json:"addToSet"`
}

func sortedKeys(m map[string]json.RawMessage) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

func (a *account) recordsModify(spaceId, objId, collection, recordsJSON string) error {
	if objId == "" || collection == "" {
		return invalid("object id and collection are required")
	}
	var in []recordIn
	if err := decodeStrict(recordsJSON, &in); err != nil {
		return err
	}
	if len(in) == 0 {
		return invalid("records is empty")
	}
	recs := make([]space.RecordModify, 0, len(in))
	for i, r := range in {
		if r.Id == "" {
			return invalid("records[%d]: id is empty", i)
		}
		var ops []space.Op
		for _, group := range []struct {
			t space.OpType
			m map[string]json.RawMessage
		}{{space.OpSet, r.Set}, {space.OpAddToSet, r.AddToSet}} {
			for _, k := range sortedKeys(group.m) {
				if k == "" || strings.HasPrefix(k, "_") || k == "id" {
					return invalid("records[%d]: field %q is reserved or empty", i, k)
				}
				v, err := jsonValue(group.m[k])
				if err != nil {
					return invalid("records[%d].%s: %v", i, k, err)
				}
				ops = append(ops, space.Op{Type: group.t, Path: k, Value: v})
			}
		}
		if len(ops) == 0 {
			return invalid("records[%d]: no set or addToSet", i)
		}
		recs = append(recs, space.RecordModify{Id: r.Id, Upsert: true, Ops: ops})
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return err
	}
	res, err := sp.Modify(a.ctx, space.ModifyBatch{ObjectId: objId, Dataset: collection, Records: recs})
	if err != nil {
		return writeErr(notFoundOrDeleted(a.ctx, sp, objId, err))
	}
	return rejectionsErr(res.Rejections)
}

const defaultRecordsLimit = 500

// recordJSON is a record without the SDK's bookkeeping fields, except
// _applySeq.
func recordJSON(v *anyenc.Value) map[string]any {
	m, _ := goValue(v).(map[string]any)
	if m == nil {
		return map[string]any{}
	}
	for k := range m {
		if strings.HasPrefix(k, "_") && k != "_applySeq" {
			delete(m, k)
		}
	}
	return m
}

func (a *account) recordsRead(spaceId, objId, collection, after string, since uint64, limit int) (map[string]any, error) {
	if objId == "" || collection == "" {
		return nil, invalid("object id and collection are required")
	}
	if limit <= 0 {
		limit = defaultRecordsLimit
	}
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	filter := map[string]any{}
	if after != "" {
		filter["id"] = map[string]any{"$gt": after}
	}
	if since > 0 {
		filter["_applySeq"] = map[string]any{"$gt": since}
	}
	q := sp.Query(objId, collection)
	if len(filter) > 0 {
		q = q.Filter(filter)
	}
	rows, err := q.Sort("id").Limit(limit + 1).All(a.ctx)
	if err != nil {
		return nil, notFoundOrDeleted(a.ctx, sp, objId, err)
	}
	var next any
	if len(rows) > limit {
		rows = rows[:limit]
		next = string(rows[limit-1].GetStringBytes("id"))
	}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		out = append(out, recordJSON(r))
	}
	return map[string]any{"records": out, "next": next}, nil
}

// ---------------------------------------------------------- derive id

// sdkObjectChangeType is the change type the SDK derives objects under
// (spaceimpl.objectChangeType). TestDeriveIdMatchesDerive holds the
// computation below to Objects().Derive.
const sdkObjectChangeType = "object"

// deriveObjectId computes the id Objects().Derive would give a seed, the
// way the SDK's Store.DeriveId does (any-sync's derived root of change
// type "object", payload = the seed, in this space, no parent), without
// writing or loading anything.
func deriveObjectId(spaceId, seed string) (string, error) {
	if spaceId == "" || seed == "" {
		return "", invalid("space id and seed are required")
	}
	root, err := objecttree.DeriveObjectTreeRoot(objecttree.ObjectTreeDerivePayload{
		ChangeType:    sdkObjectChangeType,
		ChangePayload: []byte(seed),
		SpaceId:       spaceId,
		IsEncrypted:   true,
	}, nil)
	if err != nil {
		return "", err
	}
	return root.Id, nil
}

// ---------------------------------------------------------------- exports

//export any_shim_object_derive_id
func any_shim_object_derive_id(h C.uint64_t, spaceID, seed, typeID *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if goStr(typeID) == "" {
				return invalid("type id is empty")
			}
			id, err := deriveObjectId(goStr(spaceID), goStr(seed))
			if err != nil {
				return err
			}
			return putJSON(outJSON, map[string]any{"id": id})
		})
	})
}

//export any_shim_object_patch
func any_shim_object_patch(h C.uint64_t, spaceID, targetJSON, opsJSON *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if outJSON == nil {
				return invalid("out_json is NULL")
			}
			r, err := a.objectPatch(goStr(spaceID), goStr(targetJSON), goStr(opsJSON))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_object_set_body
func any_shim_object_set_body(h C.uint64_t, spaceID, objectID, text *C.char, outErr **C.char) C.any_shim_status {
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
			return setBody(a.ctx, sp, id, goStr(text))
		})
	})
}

//export any_shim_object_read
func any_shim_object_read(h C.uint64_t, spaceID, requestJSON *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.objectRead(goStr(spaceID), goStr(requestJSON))
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
		return withAccount(h, func(a *account) error { return a.objectDelete(goStr(spaceID), goStr(objectID)) })
	})
}

//export any_shim_object_sync_state
func any_shim_object_sync_state(h C.uint64_t, spaceID, objectID *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.objectSyncState(goStr(spaceID), goStr(objectID))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_records_modify
func any_shim_records_modify(h C.uint64_t, spaceID, objectID, collection, recordsJSON *C.char, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			return a.recordsModify(goStr(spaceID), goStr(objectID), goStr(collection), goStr(recordsJSON))
		})
	})
}

//export any_shim_records_read
func any_shim_records_read(h C.uint64_t, spaceID, objectID, collection, after *C.char, since C.uint64_t, limit C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.recordsRead(goStr(spaceID), goStr(objectID), goStr(collection), goStr(after), uint64(since), int(limit))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}
