// Package blocks defines the built-in `editor_blocks` dataset and its
// per-record CRDT handler. Each record is one block of an object's
// body — paragraph, heading, list item, code, etc. — atomic at the
// field level so concurrent edits to two different blocks (or to two
// different fields of the same block) converge without losing either.
//
// Wire / storage shape of one block record:
//
//	{
//	  "id":     "<base58>" | "<base58>:<N>",  // auto-derived from
//	                                          // ChangeId; SDK suffixes
//	                                          // `:N` for the Nth (N>=1)
//	                                          // record in a multi-record
//	                                          // change. Markdown PUT
//	                                          // batches inserts, so any
//	                                          // 2+-block insert produces
//	                                          // these suffixed ids.
//	  "_ver":   { "id": "<VersionId of creating change>", ... },  // SDK-managed
//	  "type":   "paragraph" | "heading" | "list_item" |
//	            "check_list_item" | "code" | "quote" |
//	            "divider" | "html" | "table" | "image" |
//	            "front_matter",
//	  "style":  { "level": 1..6,         // heading
//	              "ordered": true|false, // list_item
//	              "number":  10,         // ordered list_item; omitted when 1
//	              "checked": true|false, // check_list_item
//	              "lang":    "go" },     // code
//	  "text":   "**bold** inline markdown",   // INLINE only, no block syntax
//	  "nav":    { "parentId": "<blockId>"|"",
//	              "pos":      "<lexid>" }
//	}
//
// Concurrency model: per-field LWW. Two clients touching the same
// `text` race; per-block atomicity means `$set text` and `$set
// style.level` from different writers converge under standard CRDT
// LWW with no merge logic required. Char-grain text CRDT is explicit
// out of scope for v1.
//
// `text` is INLINE markdown only — bold, italic, inline code, links,
// strikethrough. Block-level syntax (heading hashes, list bullets,
// fences, quote `>` prefixes) lives in `type` + `style` instead so
// the UI can render blocks structurally without re-parsing. The
// markdown package re-renders blocks → markdown by prepending the
// type-specific prefix.
package editor

import (
	"context"

	"github.com/anyproto/any-sync-sdk/handler"
)

// Module is the module slug a type names in a part's dataset
// declaration (`{"module": "editor"}`). The SDK instantiates the block
// handler once for the canonical collection (Dataset) and once per
// namespaced `<typeId>_<key>` instance a type declares.
const Module = "editor"

// Dataset is the per-object dataset that holds the block records.
const Dataset = "editor_blocks"

// Field keys on a block record. Literal strings — no
// content-addressable propIds — to keep registration hand-readable,
// matching the chat / markdown / nav patterns.
const (
	FieldType  = "type"
	FieldStyle = "style"
	FieldText  = "text"
	FieldNav   = "nav"
)

// Style sub-keys (under FieldStyle).
const (
	StyleLevel   = "level"   // heading
	StyleOrdered = "ordered" // list_item
	StyleNumber  = "number"  // ordered list_item: its number, omitted when 1
	StyleChecked = "checked" // check_list_item
	StyleLang    = "lang"    // code
)

// Nav sub-keys (under FieldNav). Local to this dataset — NOT the same
// namespace as the `nav` virtual built-in used for the object tree.
const (
	NavParentId = "parentId"
	NavPos      = "pos"
)

// RootParentId is the sentinel for "no parent — top-level block".
// Empty string keeps queries simple: `{"nav.parentId": ""}` lists the
// document's top-level blocks.
const RootParentId = ""

// dataVersion is the on-the-wire stamp pinned to writes on this
// dataset. Bump only when validation logic changes in a way that must
// reject older writers.
const dataVersion = "editor_blocks-v1"

// Validation limits. Conservative; revisit if real usage hits them.
const (
	MaxTextBytes     = 64 * 1024 // ~64 KiB per block; larger than chat MaxTextBytes by intent
	MaxTypeBytes     = 64        // "check_list_item" is the longest known value
	MaxLangBytes     = 64
	MaxParentIdBytes = 256
	MaxPosBytes      = 256
)

// Known block-type values. The handler accepts any non-empty string
// (forward-compat for clients introducing new block kinds), so this
// list is informational. Helpers in api.go and markdown.go switch on
// these values explicitly.
const (
	TypeParagraph     = "paragraph"
	TypeHeading       = "heading"
	TypeListItem      = "list_item"
	TypeCheckListItem = "check_list_item"
	TypeCode          = "code"
	TypeQuote         = "quote"
	TypeDivider       = "divider"
	TypeHTML          = "html"
	TypeTable         = "table"
	TypeImage         = "image"
	// TypeFrontMatter is a document's leading `---` metadata block; its
	// text is the lines between the delimiters, verbatim.
	TypeFrontMatter = "front_matter"
)

// NewModule returns the handler.Module to add to config.Config.Modules
// so the SDK serves every editor collection — the canonical
// `editor_blocks` every type declaring `{"module": "editor"}`
// addresses, and each namespaced instance — with the block handler.
//
//	cfg := config.Config{
//	    Modules: []handler.Module{ editor.NewModule(), chat.NewModule() },
//	    ...
//	}
func NewModule() handler.Module {
	return handler.Module{
		Name:        Module,
		Canonical:   Dataset,
		DataVersion: dataVersion,
		New: func(handler.ModuleInstance) handler.Dataset {
			return handler.Dataset{
				Handler: blocksHandler{},
				Schema:  datasetSchema(),
				Indexes: blocksHandler{}.Indexes(),
			}
		},
	}
}

// datasetSchema declares the editor_blocks field schema for apply-time
// enforcement and discovery (Space.Datasets / GET .../datasets).
//
// Dynamic so undeclared keys stay permitted (forward-compat). Every
// block field is user/DAG-written → ScopeSynced; there are no
// server-derived fields (block ids come from the change CID, `_ver` is
// SDK-managed). style and nav carry small nested objects (style.level /
// .ordered / .number / .checked / .lang; nav.parentId / .pos) so they
// declare an unconstrained object shape.
func datasetSchema() handler.Schema {
	return handler.Schema{
		Dynamic: true,
		// The text carries the `markdown` slug (the link index scans it —
		// docs/13-index.md § Links); the block kind is an enum, style and
		// nav are nested objects, so those describe themselves in prose.
		Fields: []handler.Field{
			{Id: FieldType, Name: "Type", Schema: handler.Leaf(handler.PropertyKindString), Scope: handler.ScopeSynced,
				Description: "Block kind: paragraph, heading, list_item, …"},
			{Id: FieldStyle, Name: "Style", Schema: handler.Leaf(handler.PropertyKindObject), Scope: handler.ScopeSynced,
				Description: "Per-kind rendering options: level, ordered, number, checked, lang, …"},
			{Id: FieldText, Name: "Text", Schema: handler.Leaf(handler.PropertyKindString), Scope: handler.ScopeSynced,
				Description: "Block body, inline markdown only; empty for an empty paragraph.",
				XFormat:     map[string]any{"type": "markdown"}},
			{Id: FieldNav, Name: "Nav", Schema: handler.Leaf(handler.PropertyKindObject), Scope: handler.ScopeSynced,
				Description: "Tree placement: {parentId, pos} with a lexid pos."},
		},
	}
}

// blocksHandler is the CRDT handler owning the editor_blocks dataset.
// Implementation lives in handler.go; the type is declared here so
// blocks.go is self-contained for the registration story.
type blocksHandler struct {
	handler.DefaultHandler
}

func (blocksHandler) Init(_ context.Context) error { return nil }
