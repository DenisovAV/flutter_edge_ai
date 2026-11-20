# testdata

`nodeconf-dead.yml` is any-sync-sdk v0.7.4's `e2e/local.yml` (the SDK's own
local test network) with every node address rewritten to `127.0.0.1:9`, a
closed port. An account opened with it reaches no node: sync runs over LAN
p2p only, or not at all. Tests use it with fresh mnemonics and never contact
a real network.
