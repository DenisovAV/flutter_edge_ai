import 'package:flutter_gemma/flutter_gemma.dart' show Tool;

/// The four built-in [Tool]s the agent gives the model. Their names + parameter
/// schemas mirror Gallery's `AgentTools.kt` (`load_skill` / `runJs` / `runIntent`
/// / `runMcpTool`) so small function-calling models call them reliably; only the
/// Dart-side names differ ([runSkill] is Gallery's JS `runJs`, [runMcp] its
/// `runMcpTool`).
///
/// Two-stage discovery (Gallery's trick): the system prompt lists only each
/// selected skill's name + description. The full SKILL.md instructions are
/// pulled on demand by the model via [loadSkill], keeping context small when
/// many skills are selected.
abstract final class AgentToolNames {
  /// `loadSkill(skillName)` — pull a skill's full SKILL.md instructions.
  static const loadSkill = 'loadSkill';

  /// `runSkill(skillName, data)` — run a JS skill's script (Gallery's `runJs`,
  /// minus its `scriptName`: the script comes from the skill's own SKILL.md).
  static const runSkill = 'runSkill';

  /// `runIntent(intent, parameters)` — fire a native OS intent.
  static const runIntent = 'runIntent';

  /// `runMcp(toolName, input)` — call a tool on a remote MCP server
  /// (Gallery's `runMcpTool`).
  static const runMcp = 'runMcp';
}

/// `loadSkill(skillName)` — second-stage discovery. The model calls this to read
/// a selected skill's full instructions before acting on it.
const Tool loadSkillTool = Tool(
  name: AgentToolNames.loadSkill,
  description:
      'Loads a skill and returns its full instructions. '
      'Call this first with a skill name from the available skills list, '
      'then follow the returned instructions to complete the task.',
  parameters: {
    'type': 'object',
    'properties': {
      'skillName': {
        'type': 'string',
        'description': 'The name of the skill to load.',
      },
    },
    'required': ['skillName'],
  },
);

/// `runSkill(skillName, data)` — run a JavaScript skill's script in a sandboxed
/// webview (Gallery's `runJs`). The script exposes
/// `window.ai_edge_gallery_get_result(data, secret)`.
///
/// Which script runs is the skill's decision, not the model's: [AgentLoop]
/// looks the skill up in the registry and [JsSkillExecutor] resolves it via
/// [Skill.scriptName], parsed from SKILL.md.
const Tool runSkillTool = Tool(
  name: AgentToolNames.runSkill,
  description: 'Runs a JS script for a skill.',
  parameters: {
    'type': 'object',
    'properties': {
      'skillName': {'type': 'string', 'description': 'The name of the skill.'},
      // No `scriptName` here, deliberately. Gallery's schema has one, but which
      // script a skill runs is decided by the skill's own SKILL.md (parsed into
      // `Skill.scriptName`, defaulting to index.html) and resolved by
      // `JsSkillExecutor.sourceFor` — the model's answer was never read. Asking
      // for it made the model invent a filename to satisfy a required field,
      // and honouring one would let it name any file under the skill's
      // scripts/ directory, which the SKILL.md value cannot.
      'data': {
        'type': 'string',
        'description':
            'The data to pass to the script as a JSON string. Use an empty '
            'string if not provided by user.',
      },
    },
    'required': ['skillName', 'data'],
  },
);

/// `runIntent(intent, parameters)` — run a native intent to interact with the
/// device (email / calendar / notification / …) from a whitelist behind OS/user
/// confirmation.
const Tool runIntentTool = Tool(
  name: AgentToolNames.runIntent,
  description:
      'Run a native intent. It is used to interact with the device '
      'to perform certain actions.',
  parameters: {
    'type': 'object',
    'properties': {
      'intent': {'type': 'string', 'description': 'The intent to run.'},
      'parameters': {
        'type': 'string',
        'description':
            'A JSON string containing the parameter values required for the '
            'intent.',
      },
    },
    'required': ['intent', 'parameters'],
  },
);

/// `runMcp(toolName, input)` — call a tool on a connected MCP (Model Context
/// Protocol) server (Gallery's `runMcpTool`).
const Tool runMcpTool = Tool(
  name: AgentToolNames.runMcp,
  description: 'Run an MCP tool.',
  parameters: {
    'type': 'object',
    'properties': {
      'toolName': {
        'type': 'string',
        'description': 'The name of the tool to run.',
      },
      'input': {
        'type': 'string',
        'description':
            'The parameters passed to the tool as input '
            '(a JSON string).',
      },
    },
    'required': ['toolName', 'input'],
  },
);

/// The four built-in agent tools, in the order the model sees them. Pass these
/// to `createChat(tools: agentTools)`.
const List<Tool> agentTools = [
  loadSkillTool,
  runSkillTool,
  runIntentTool,
  runMcpTool,
];
