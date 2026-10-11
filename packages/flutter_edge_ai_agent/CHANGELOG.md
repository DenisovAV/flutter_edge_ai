## 0.2.8
- Unset sampling values reach the engine unset (#572).
- Require `flutter_edge_ai` ^2.2.0.

## 0.2.7
- Bundled SKILL.md files now ship; `AssetSkillSource.load()` throws when one is missing.
- Require `flutter_edge_ai` 2.x.

## 0.2.6
- Renamed from `flutter_gemma_agent`.

- README: web native-intent behaviour, Android release builds, and installing the agent skills.

## 0.2.5

- fix: drop runSkill's required scriptName — the script comes from the skill's SKILL.md.

## 0.2.4

- docs: document the imageBytes vision API in the package README.

## 0.2.3

- feat: AgentSession.ask / AgentLoop.run accept an optional imageBytes — vision-capable agent turns (requires supportImage: true).
- feat: McpClient advertises MCP protocol revision 2025-11-25 + negotiated-version header on every request.

## 0.2.2

- AgentLoop delegates its tool loop to core generateChatResponseWithTools (single balancing impl); fed-back tool-response now carries the model's original call name.

## 0.2.1

- AgentSession.ask now streams the final answer token-by-token (VoiceSession parity); balance pending tool-calls on a mid-stream error.

## 0.2.0

- Add optional isCancelled to AgentLoop.run / AgentSession.ask for barge-in / cancellation.

## 0.1.0

* Initial pure-Dart foundation: Skill model + SKILL.md parser (Gallery-compatible).
* Sealed SkillResult (text/image/widget/webview/error) + SkillExecutor probe-chain abstraction.
* SkillRegistry (select/discovery string) + in-memory SecretStore (never in prompt).
* Agent loop over existing function-calling: 4 built-in tools, parallel-call dispatch, maxIterations guard.
* AgentSession facade (ask → AgentEvent stream) with two-stage skill discovery + injected secrets.
* TextSkillExecutor (0 deps): text-only persona skills resolve to a no-op acknowledgement.
* McpSkillExecutor + McpClient: call MCP tools over Streamable HTTP with a per-call permission hook (default-deny).
* NativeIntentExecutor: whitelist of 6 OS intents (email/SMS/calendar/notification/date) with param validation, behind user confirm.
* AgentChatView: chat widget over the AgentEvent stream with a collapsible progress panel + inline image/webview/widget results.
* Adaptive SkillManagerView + McpManagerView (bottom sheet on narrow, side panel on wide).
* SecretEditorDialog, McpToolCallPermissionDialog, SkillTesterView, and the add-skill security disclaimer.
* Bundled 8 starter skills (Gallery, Apache-2.0): JS/intent/text covering all four mechanisms.
* AssetSkillSource: load bundled SKILL.md skills + wire JsSkillExecutor to their bundled HTML.
* Verified on Android, iOS, macOS, and Windows; the agent is not supported on web yet (browser LLM runtimes don't reliably emit tool calls).
