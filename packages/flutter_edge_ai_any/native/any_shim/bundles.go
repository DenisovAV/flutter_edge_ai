package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/anyproto/any-sync-sdk/handler"
	"github.com/anyproto/any-sync-sdk/space"

	editor "anyshim/third_party/any_editor"
)

// The two RAG bundles. These declarations are frozen from the first
// publish on: any-sync never changes a declared part, dataset or
// property, and two devices with different declarations under one id
// would converge on whichever install won. A change needs a new bundle
// id (…/v2). TestRagBundleDeclarationsFrozen pins every field.
const (
	ragLocationBundleId = "flutter_edge_ai.rag.location/v1"
	ragDocumentBundleId = "flutter_edge_ai.rag.document/v1"

	tombstonesDatasetKey = "tombstones"
)

func ragLocationBundle() space.EnsureBundleRequest {
	return space.EnsureBundleRequest{
		Id:          ragLocationBundleId,
		Name:        "RAG location",
		DerivedRoot: true,
		XKey:        "flutter_edge_ai.rag.location",
		Hidden:      true,
		Properties: []space.PropertyDraft{
			// One leaf per modality: core.<text|image|audio> = {"fmt":1}.
			// Two leaves are a conflict every reader sees.
			{Name: "core", XKey: "core", Kind: space.PropertyKindObject},
			{Name: "fields", XKey: "fields", Kind: space.PropertyKindObject},
			{Name: "profiles", XKey: "profiles", Kind: space.PropertyKindObject},
			// Monotone: textSearch.on = true, never unset.
			{Name: "textSearch", XKey: "textSearch", Kind: space.PropertyKindObject},
		},
		Parts: []space.PartDraft{{
			Key:    "tomb",
			Name:   "Tombstones",
			Hidden: true,
			Datasets: []space.DatasetDraft{{
				Key:    tombstonesDatasetKey,
				Module: space.RecordsModule,
				IdRule: space.IdUser,
				// sha256(key), or a reserved name such as "clear"
				// (readers ignore reserved ids they do not know).
				IdPattern: `[0-9a-f]{64}|[a-z][a-z0-9_]{0,31}`,
				IdMaxLen:  64,
				DeleteBy:  space.DeleteByNone,
				Fields: []space.DatasetFieldDraft{
					// Re-written by every remove of the key, so mutable.
					{Key: "key", Kind: space.PropertyKindString, Shape: handler.Leaf(handler.PropertyKindString), MutableBy: space.MutableByAnyone},
					// Written only with $addToSet: a commutative max.
					{Key: "revs", Kind: space.PropertyKindArray, Shape: revsShape(), MutableBy: space.MutableByAnyone},
				},
			}},
		}},
	}
}

// revsShape: an array of numbers.
func revsShape() *handler.FieldShape {
	s := handler.Leaf(handler.PropertyKindArray)
	s.Items = handler.Leaf(handler.PropertyKindNumber)
	return s
}

func ragDocumentBundle() space.EnsureBundleRequest {
	return space.EnsureBundleRequest{
		Id:          ragDocumentBundleId,
		Name:        "RAG document",
		DerivedRoot: true,
		XKey:        "flutter_edge_ai.rag.document",
		Hidden:      true,
		Properties: []space.PropertyDraft{
			{Name: "doc", XKey: "doc", Kind: space.PropertyKindString},
			{Name: "vecs", XKey: "vecs", Kind: space.PropertyKindObject},
		},
		Parts: []space.PartDraft{{
			Key:  "body",
			Name: "Body",
			// The editor's canonical dataset, so object_set_body writes a
			// body `any` renders.
			UI:       map[string]any{"type": "document"},
			Datasets: []space.DatasetDraft{{Module: editor.Module}},
		}},
	}
}

// bundleIds is what a caller needs of one installed bundle.
type bundleIds struct {
	RootId     string            `json:"rootId"`
	Properties map[string]string `json:"properties"`
	Tombstones string            `json:"tombstones,omitempty"`
}

// readBundleIds reads the root's property ids by XKey (never computed:
// a property added later through AddProperty has a change-derived id)
// and, when wantDataset is set, the collection of that dataset. Missing
// definitions are ANY_SHIM_ERR_NOT_FOUND: they have not synced here yet.
// A definition of another kind is ANY_SHIM_ERR_REFUSED: the id is
// taken by someone else's declaration.
func readBundleIds(ctx context.Context, sp space.Space, req space.EnsureBundleRequest, root, wantDataset string) (bundleIds, error) {
	out := bundleIds{RootId: root, Properties: map[string]string{}}
	// Absence is an empty list (the SDK's answer for a root it has no
	// definitions of yet); an error is a real failure and stays one.
	props, err := sp.Types().Properties(ctx, root)
	if err != nil {
		return out, fmt.Errorf("bundle %s: properties of %s: %w", req.Id, root, err)
	}
	if len(props) == 0 {
		return out, withCode(codeNotFound, "bundle %s: the definitions of %s have not synced here", req.Id, root)
	}
	byX := map[string][]space.PropertyDef{}
	for _, p := range props {
		byX[p.XKey] = append(byX[p.XKey], p)
	}
	for _, d := range req.Properties {
		defs := byX[d.XKey]
		if len(defs) == 0 {
			// The root has definitions, but not this one: it was removed
			// (RemoveProperty), not "not synced yet". Safe because a
			// bundle's definitions arrive together: any-sync-sdk v0.7.4
			// declares every missing one in ONE change (one localWrite of
			// all records, internal/spaceimpl/bundles.go declareProperties,
			// line 412, the write at line 457), so a device never holds
			// some of them without the others. TestRagBundlesRemovedPropertyRefused.
			return out, withCode(codeRefused, "bundle %s: property %q is declared by this build but missing from the root's definitions (removed)", req.Id, d.XKey)
		}
		// Two of one XKey only through AddProperty on another device;
		// the smaller id is the one every device picks.
		sort.Slice(defs, func(i, j int) bool { return defs[i].Id < defs[j].Id })
		if defs[0].Kind != d.Kind {
			return out, withCode(codeRefused, "bundle %s: property %q has kind %d, this build declares %d", req.Id, d.XKey, defs[0].Kind, d.Kind)
		}
		out.Properties[d.XKey] = defs[0].Id
	}
	if wantDataset != "" {
		dss, err := sp.Types().Datasets(ctx, root)
		if err != nil {
			return out, fmt.Errorf("bundle %s: datasets of %s: %w", req.Id, root, err)
		}
		for _, ds := range dss {
			if ds.Key == wantDataset {
				out.Tombstones = ds.Collection
			}
		}
		if out.Tombstones == "" {
			return out, withCode(codeNotFound, "bundle %s: dataset %q has not synced here", req.Id, wantDataset)
		}
	}
	return out, nil
}

// ragBundle installs (ensure) or only reads one bundle.
func ragBundle(ctx context.Context, sp space.Space, req space.EnsureBundleRequest, ensure bool, wantDataset string) (bundleIds, error) {
	derived, err := sp.Bundles().DerivedRootId(ctx, req.Id)
	if err != nil {
		return bundleIds{}, err
	}
	if ensure {
		b, _, err := sp.Bundles().Ensure(ctx, req)
		if err != nil {
			return bundleIds{}, writeErr(err)
		}
		if !b.Derived || b.RootId != derived {
			return bundleIds{}, withCode(codeRefused,
				"bundle %s is installed on root %s, not on its derived root %s (derived=%v): refused", req.Id, b.RootId, derived, b.Derived)
		}
	} else if b, err := sp.Bundles().Get(ctx, req.Id); err == nil && b.RootId != derived {
		return bundleIds{}, withCode(codeRefused,
			"bundle %s is installed on root %s, not on its derived root %s: refused", req.Id, b.RootId, derived)
	} else if err != nil && !errors.Is(err, space.ErrBundleUnknown) && !errors.Is(err, space.ErrBundleRootNotSynced) {
		if c := codeOf(err); c == codeClosed || c == codeTimeout {
			return bundleIds{}, err
		}
	}
	return readBundleIds(ctx, sp, req, derived, wantDataset)
}

func (a *account) ragBundles(spaceId string, ensure bool) (map[string]any, error) {
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	loc, err := ragBundle(a.ctx, sp, ragLocationBundle(), ensure, tombstonesDatasetKey)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ragLocationBundleId, err)
	}
	doc, err := ragBundle(a.ctx, sp, ragDocumentBundle(), ensure, "")
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ragDocumentBundleId, err)
	}
	return map[string]any{"location": loc, "document": doc}, nil
}

//export any_shim_rag_bundles
func any_shim_rag_bundles(h C.uint64_t, spaceID *C.char, ensure C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.ragBundles(goStr(spaceID), ensure != 0)
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}
