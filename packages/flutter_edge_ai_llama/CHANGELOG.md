# Changelog

## Unreleased

- Examples use `openSession`/`openChat` and close returned handles.
- `responseFormat` on `openSession`/`openChat`, enforced by llamadart's grammar (#195).

## 0.0.6

- Update llamadart to 0.17.5 with matching Apple and Web runtimes (#764).
- Require `flutter_edge_ai` >=2.5.0 <2.6.0.

## 0.0.5

- Docs: on the web, load `cache_api.js` inside the `<head>` of `web/index.html` (#728).

## 0.0.4

- Docs: LiteRT-LM keeps Swift Package Manager on from litertlm 1.19.0 (#689).

## 0.0.3

- Add native EmbeddingGemma 2 GGUF text embeddings; requires core 2.5.0 and llamadart 0.15.1.

## 0.0.2
- Upgrade llamadart to 0.15.0 with matching Apple and Web runtimes.

## 0.0.1

- Add llama.cpp-powered GGUF inference through llamadart.
