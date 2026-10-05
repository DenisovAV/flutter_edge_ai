# fluttergemma.dev → flutteredge.ai

Deployed by hand to the Firebase Hosting site `fluttergemma` (project
`aichat-c0c27`), which serves `fluttergemma.dev`. Every path answers 301 with the
same path on https://flutteredge.ai, so old links to `/docs/*`, `/codelabs/*` and
`/try` land on their new page. `public/index.html` is only a fallback for a
client that ignores the redirect.

    cd website/legacy_redirect
    firebase deploy --only hosting --project aichat-c0c27

Nothing in CI deploys this; the main site deploys from `website/` to the
`flutteredge-ai` site.
