# ADR 0007 — Reading recipes as data, with a self-check, captures and a text fallback

**Status:** accepted, 2026-10-06
**Relates to:** ADR 0002 (the model never produces a number), ADR 0006 (dynamic design),
DD-R26/R27 in the design notes

## Context

Motormind reads vehicle listings from the page the person has open in the in-app web
pane. The first reader was two pattern strategies over the page's visible text, written in
Dart. That works until a site changes its markup, and then it fails in the worst way:
quietly, with fewer or wrong cards. Three things followed from using it on real sites:

1. **Sites change, and the fix must not be a release.** A reader that lives in compiled
   Dart can only be repaired by shipping a new app.
2. **The on-device model must not parse HTML.** It is small, slow at long inputs, and the
   numeric guard (ADR 0002) depends on numbers coming from code, not prose.
3. **Automated page loads look like a bot.** Testing the reader by driving an emulator
   against live sites got the emulator's WebView blocked by two of three curated sites in
   an hour. Real pages have to reach the tests another way.

## Decision

- **A recipe per site, as JSON.** `ReadingRecipe` names the listing card selector, where
  each field sits inside a card (selector, attributes to try, an optional regex), and
  self-check rules. Recipes ship as assets and can be replaced at runtime from the app's
  documents folder; a higher version wins. One generic `RecipeReader` (pure Dart over
  `package:html`) interprets every recipe, so it runs identically in a unit test over a
  saved page and on the phone.
- **A self-check with every read.** A read passes only if it is plausible: enough cards,
  most with a price, images when the recipe reads them, and never more cards than the
  page's own total. A recipe that fails on a real page is marked `broken` (after two
  failures if it was `verified`, at once if it was `unverified`), the stage says so, and
  the model is told. A half-working read is treated as a failure, because it is the
  dangerous case.
- **The text strategies stay as the floor.** When no recipe applies, or the recipe fails
  its self-check, the generic text patterns read the page. Every page gets at least that.
- **Captures instead of crawling.** The web pane has a Capture control. It saves the page
  as rendered (HTML, title, URL, the recipe's verdict on that page) to the device, tagged
  with the test task it answers. Captured pages are pulled off the device and become test
  fixtures. The app never loads a page the person did not ask for, and the test suite
  never touches a live site.
- **Repair is a drop-in.** Because a recipe is data with a self-check, a repaired recipe
  can come from a person editing JSON today or from a hosted help service later (a larger
  model that receives the page structure and the broken recipe, never the person's data).
  The app keeps the old recipe marked broken until the new one passes.
- **Lazy content is loaded the way a person loads it.** Right after the app itself opens
  a results page, it scrolls a screen at a time with a pause, then returns to the top, so
  lazily rendered cards and images exist before the read. It never scrolls a page the
  person is reading.

## Consequences

- Shipped recipes start as `unverified` (written from documentation or from the rendered
  text) and become `verified` the first time they pass on a real page. Today both
  EchoPark and Cars.com recipes are unverified; the text strategies carry the demo until
  captures arrive.
- The recipe format is the contract the help service would implement; it has to stay
  small and boring.
- Tests: `advisor_core/test/reading_recipe_test.dart` reads a synthetic Cars.com-shaped
  page and checks that markup changes, missing prices and implausible counts all fail the
  self-check. Real captures replace the synthetic fixture as they are collected.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep per-site readers in Dart | Repair means a release; the help-service idea is impossible. |
| Let the model read the HTML | Too slow at 100 KB inputs, and a path around the numeric guard. |
| Headless fetching for tests | Exactly the bot behavior the sites block, and against the project's posture (the pane is the person's browser). |
| Site APIs | None of the curated sites offer a public one; the page the person sees is the honest source. |
