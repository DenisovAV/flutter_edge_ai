/// On-device agentic skills for flutter_gemma.
///
/// An opt-in satellite package that turns the inference core into an on-device
/// agent: the model is given a set of *skills* (SKILL.md), decides which to
/// invoke via flutter_gemma's existing function-calling, runs them, and feeds
/// results back — fully offline. Gallery-compatible (google-ai-edge/gallery,
/// Apache-2.0): their SKILL.md catalog parses unmodified.
///
/// This release exposes the pure-Dart foundation — the [Skill] model + SKILL.md
/// parser, the [SkillRegistry], the [SkillExecutor] probe-chain abstraction +
/// sealed [SkillResult], and the [SecretStore] — plus the agentic orchestration
/// over flutter_gemma's existing function-calling: the four built-in
/// [agentTools], the [AgentLoop], and the [AgentSession] facade with its
/// [AgentEvent] stream. It also includes the concrete executors — the
/// [TextSkillExecutor], the [JsSkillExecutor] (the only executor importing
/// `webview_flutter` — runs a skill's `scripts/index.html` in a sandboxed
/// headless webview), the [McpSkillExecutor], and the [NativeIntentExecutor]
/// (a whitelist of OS intents behind user/OS confirmation).
///
/// It also ships the cross-platform Flutter UI the host app mounts: the
/// [AgentChatView] (chat driven by the [AgentEvent] stream, with a collapsible
/// agent-steps panel and inline image / webview / native-widget results), the
/// adaptive [SkillManagerView] and [McpManagerView] (bottom sheet on narrow,
/// side panel on wide), the [SecretEditorDialog], the per-call
/// [McpToolCallPermissionDialog], the [SkillTesterView], and the
/// [AddSkillDisclaimerDialog] security warning.
library;

export 'src/agent_event.dart';
export 'src/agent_loop.dart';
export 'src/agent_session.dart';
export 'src/agent_tools.dart';
export 'src/executors/js_skill_executor.dart';
export 'src/executors/mcp_skill_executor.dart';
export 'src/executors/native_intent_executor.dart';
export 'src/executors/text_skill_executor.dart';
export 'src/mcp/mcp_client.dart';
export 'src/mcp/mcp_server_config.dart';
export 'src/secret_store.dart';
export 'src/skill.dart';
export 'src/skill_executor.dart';
export 'src/skill_md_parser.dart';
export 'src/skill_registry.dart';
export 'src/skill_result.dart';
export 'src/sources/asset_skill_source.dart';
// Cross-platform UI widgets the host app mounts (chat view, skill / MCP
// managers, secret + permission dialogs, skill tester, security disclaimer).
export 'src/ui/add_skill_disclaimer.dart';
export 'src/ui/agent_chat_view.dart';
export 'src/ui/mcp_manager_view.dart';
export 'src/ui/mcp_permission_dialog.dart';
export 'src/ui/secret_editor_dialog.dart';
export 'src/ui/skill_manager_view.dart';
export 'src/ui/skill_result_view.dart';
export 'src/ui/skill_tester_view.dart';
