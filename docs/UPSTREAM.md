# Upstream relationship

This repository is a fork of [DenisovAV/flutter_edge_ai](https://github.com/DenisovAV/flutter_edge_ai)
taken on 2026-10-03 at commit `12e505d4` (the `flutter_gemma` → `flutter_edge_ai` rebrand
merge). It is not an effort to contribute back; see ADR 0005.

## Branches

| Branch | Role |
|---|---|
| `main` | mirrors upstream `main` as of the fork; never carries project commits |
| `develop` | trimmed of upstream's codelabs, website, tooling and workflows; all Motormind work |

## What stays from upstream

`packages/` (the inference engines, agent loop, speech, RAG, diagnostics and Genkit
packages), `LICENSE`, the root `pubspec.yaml` workspace definition, and the two tracked
upstream docs `docs/LEGACY_API.md` and `docs/benchmarks/`.

Treat `packages/` as read-mostly. A patch there is fine when the app needs it; record it in
the commit message with "upstream patch:" so it can be found if a merge is ever attempted.

## What was removed on `develop`

`codelabs/`, `website/`, `tool/`, `.github/workflows/*` (upstream's), `.github/CICD.md`,
`.github/WORKFLOWS.md`, `.claude/` (upstream's release skills and hooks), `.fvm/` (now
git-ignored; `.fvmrc` remains), `skills_lint.yaml`, and upstream's `AGENTS.md` (replaced).

## Merging upstream, if ever needed

```bash
git remote add upstream git@github.com:DenisovAV/flutter_edge_ai.git
git fetch upstream
git checkout main && git merge --ff-only upstream/main
git checkout develop && git merge main
```

Expect conflicts only in deleted directories (resolve by deleting again) and in the root
`pubspec.yaml` workspace list.
