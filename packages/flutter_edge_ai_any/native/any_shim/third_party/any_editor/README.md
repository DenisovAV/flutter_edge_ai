# any_editor

`blocks.go` and `handler.go` are copied byte for byte from
[anyproto/any](https://github.com/anyproto/any) v0.4.1, `internal/editor/`
(MIT License, Copyright (c) 2026 Any Association; see `LICENSE` here). They
define the `editor_blocks` dataset and its record handler: the module `any`
registers for an object's body, which the shim registers too, so `any`
renders the bodies the shim writes and the shim reads the ones `any` writes.

The files are not modified, so a later `any` release can be compared with
`diff` and taken as a whole. The package is `internal` upstream; until
anyproto publishes it as part of the SDK, this copy goes stale if `any`
changes the block schema (`editor_blocks-v1`).
