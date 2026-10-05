# Legacy `flutter_gemma*` packages

The `flutter_gemma` family was renamed to `flutter_edge_ai` in October 2026. Each
directory here is the **final release under the old name**: the archive pub.dev
served for that package's last version, unpacked, with only these changes —

- `README.md` opens with a notice pointing to the new package and the
  [migration guide](https://flutteredge.ai/docs/migration);
- `CHANGELOG.md` and `version:` move one patch up; `pubspec.yaml` drops
  `resolution: workspace` (these are not workspace members) and points its links
  at this repository;
- `flutter_gemma_agent` additionally ships the four bundled `SKILL.md` files its
  last archive was missing (#578).

The code under `lib/` is byte-identical to what was published. After these
releases each package is marked discontinued on pub.dev, replaced by its
`flutter_edge_ai*` counterpart. Nothing here is built or tested by CI.
