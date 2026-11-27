// LiteRT-LM's canonical Gemma 4 chat template, for the Gemma 4 bundles whose
// own template is older than it.
//
// The Gemma 4 E2B and E4B `.litertlm` files on litert-community embed the
// repository's `chat_template.jinja` (read from the generic, Google Tensor
// G5/G6, Qualcomm QCS8275 and Intel LNL/PTL E2B files, the `-web` E2B file and
// the generic E4B file). Rendered by LiteRT-LM's conversation, that template:
//
// * prefills `<|tool_response>` twice after a tool call: decoding stops on it
//   and keeps it in the KV cache, and the tool message renders it again
//   (LiteRT-LM f240215c; measured on LiteRT-LM 0.19.1 and 0.20.0 with the
//   conversation's token count, 276 tokens after the tool turn vs 275);
// * after a tool response with thinking on, starts no thought, where Hugging
//   Face's template and LiteRT-LM's own open `<|channel>thought`;
// * closes a model turn that only called tools with `<turn|>`, so a history
//   replayed as full messages differs from the KV cache of the turn it was.
//
// The canonical template is `models/gemma4/chat_template_e2b_e4b.jinja` of
// the pinned LiteRT-LM v0.20.0 (95df4c2a). Measured on Gemma 4 E2B, LiteRT-LM
// 0.20.0 (the D8 tool cases, with the thoughts of a conversation with tools
// kept, channel_content_filter.dart): replies to a tool result with no text,
// thinking on, fell from 18 of 54 to 2 (CPU) and from 21 of 54 to 1 (Metal)
// with the bundle's sampler, and from 10 of 18 to 0 and 7 of 18 to 0 greedy.
// With thinking off an action tool's `{status: success}` still often ends the
// turn at once, as it does on Hugging Face's prompt: 33 of 90 to 30 (CPU), 22
// of 90 to 30 (Metal).
//
// The canonical template strips no thought from a model message's text, so
// the history a conversation replays must hold none (conversation_handles).
import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' show sha256;

/// The sha256 of the jinja template litert-community's Gemma 4 E2B and E4B
/// bundles embed (`LlmMetadata.jinja_prompt_template`).
const gemma4CommunityTemplateSha256 =
    '02b3091acf53c0b722e3db0c7a1b4980363edcc2d85549dafa339ff5dbfff629';

/// The template a conversation on a bundle whose own is [bundleTemplate]
/// renders with instead, or null to keep the bundle's. Only a template known
/// to be stale is replaced; any other, including a later one, is kept.
String? promptTemplateOverrideFor(String? bundleTemplate) {
  if (bundleTemplate == null) return null;
  final digest = sha256.convert(utf8.encode(bundleTemplate)).toString();
  return digest == gemma4CommunityTemplateSha256
      ? gemma4E2bE4bChatTemplate
      : null;
}

/// LiteRT-LM's `models/gemma4/chat_template_e2b_e4b.jinja` at v0.20.0
/// (95df4c2a; Apache License 2.0, see NOTICES), byte for byte. Renders a conversation as
/// Hugging Face's google/gemma-4-E2B-it template does, except that it keeps
/// no thought: LiteRT-LM takes a model's thoughts out of its messages
/// (`channels`), and Hugging Face's renders the thoughts of the turn in
/// progress.
const gemma4E2bE4bChatTemplate = r'''{%- macro format_parameters(properties) -%}
    {%- for key, value in properties | dictsort -%}
        {%- set add_comma = false -%}
        {%- if not loop.first %},{% endif -%}
        {{ key }}:{
            {%- if value['description'] -%}
                description:<|"|>{{ value['description'] }}<|"|>
                {%- set add_comma = true -%}
            {%- endif -%}
            {%- if value['nullable'] %}
                {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                nullable:true
            {%- endif -%}
            {%- if value['type'] | upper == 'STRING' -%}
                {%- if value['enum'] -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    enum:{{ format_argument(value['enum']) }}
                {%- endif -%}
            {%- elif value['type'] | upper == 'OBJECT' -%}
                ,properties:{
                {%- if value['properties'] is defined and value['properties'] is mapping -%}
                    {{- format_parameters(value['properties']) -}}
                {%- elif value is mapping -%}
                    {{- format_parameters(value) -}}
                {%- endif -%}
                }
                {%- if value['required'] -%}
                    ,required:{{ format_argument(value['required']) }}
                {%- endif -%}
            {%- elif value['type'] | upper == 'ARRAY' -%}
                {%- if value['items'] is mapping and value['items'] -%}
                    ,items:{
                    {%- for item_key, item_value in value['items'] | dictsort if item_value is not none -%}
                        {%- if not loop.first %},{% endif -%}
                        {%- if item_key == 'properties' -%}
                            properties:{
                            {%- if item_value is mapping -%}
                                {{- format_parameters(item_value) -}}
                            {%- endif -%}
                            }
                        {%- elif item_key == 'type' -%}
                            {%- if item_value is string -%}
                                type:{{ format_argument(item_value | upper) }}
                            {%- else -%}
                                type:{{ format_argument(item_value | map('upper') | list) }}
                            {%- endif -%}
                        {%- else -%}
                            {{ item_key }}:{{ format_argument(item_value) }}
                        {%- endif -%}
                    {%- endfor -%}
                    }
                {%- endif -%}
            {%- endif -%}
            {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
            type:<|"|>{{ value['type'] | upper }}<|"|>}
    {%- endfor -%}
{%- endmacro -%}

{%- macro format_function_declaration(tool_data) -%}
    declaration:{{- tool_data['function']['name'] -}}{description:<|"|>{{- tool_data['function']['description'] -}}<|"|>
    {%- set params = tool_data['function']['parameters'] -%}
    {%- if params -%}
        ,parameters:{
        {%- if params['properties'] -%}
            properties:{ {{- format_parameters(params['properties']) -}} },
        {%- endif -%}
        {%- if params['required'] -%}
            required:{{ format_argument(params['required']) }},
        {%- endif -%}
        {%- if params['type'] -%}
            type:<|"|>{{- params['type'] | upper -}}<|"|>}
        {%- endif -%}
    {%- endif -%}
    {%- if 'response' in tool_data['function'] -%}
        {%- set response_declaration = tool_data['function']['response'] -%}
        ,response:{
        {%- if response_declaration['description'] -%}
            description:<|"|>{{- response_declaration['description'] -}}<|"|>,
        {%- endif -%}
        {%- if response_declaration['type'] | upper == 'OBJECT' -%}
            type:<|"|>{{- response_declaration['type'] | upper -}}<|"|>}
        {%- endif -%}
    {%- endif -%}
    }
{%- endmacro -%}

{%- macro format_argument(argument, escape_keys=True) -%}
    {%- if argument is string -%}
        {{- '<|"|>' + argument + '<|"|>' -}}
    {%- elif argument is boolean -%}
        {{- 'true' if argument else 'false' -}}
    {%- elif argument is mapping -%}
        {{- '{' -}}
        {%- for key, value in argument | dictsort -%}
            {%- if not loop.first %},{% endif -%}
            {{- ('<|"|>' + key + '<|"|>') if escape_keys else key -}}:{{- format_argument(value, escape_keys=escape_keys) -}}
        {%- endfor -%}
        {{- '}' -}}
    {%- elif argument is sequence -%}
        {{- '[' -}}
        {%- for item in argument -%}
            {{- format_argument(item, escape_keys=escape_keys) -}}
            {%- if not loop.last %},{% endif -%}
        {%- endfor -%}
        {{- ']' -}}
    {%- else -%}
        {{- argument -}}
    {%- endif -%}
{%- endmacro -%}

{%- macro format_content(content) -%}
    {%- for item in content -%}
        {%- if item['type'] == 'text' -%}
            {{- item['text'] | trim -}}
        {%- elif item['type'] == 'image' -%}
            {{- '\n\n<|image|>\n\n' -}}
        {%- elif item['type'] == 'audio' -%}
            {{- '<|audio|>' -}}
        {%- endif -%}
    {%- endfor -%}
{%- endmacro -%}

{%- set thinking = enable_thinking | default(false) -%}
{%- set ns = namespace(prev_message_type=None) -%}
{%- set is_first_system = messages and messages[0]['role'] == 'system' -%}
{%- set loop_messages = messages[1:] if is_first_system else messages -%}
{#- Handle System/Tool Definitions Block -#}
{%- if thinking or tools or is_first_system -%}
    {{- '<|turn>system' -}}

    {#- Inject Thinking token at the very top of the FIRST system turn -#}
    {%- if thinking -%}
        {{- '\n<|think|>' -}}
    {%- endif -%}

    {%- if is_first_system -%}
        {{- '\n' + format_content(messages[0]['content']) -}}
    {%- endif -%}

    {%- if tools -%}
        {{- '\n' -}}
        {%- for tool in tools %}
            {{- '<|tool>' -}}
            {{- format_function_declaration(tool) | trim -}}
            {{- '<tool|>' -}}
        {%- endfor %}
    {%- endif -%}

    {{- '<turn|>\n' -}}
{%- endif %}

{#- Loop through messages -#}
{%- for message in loop_messages -%}
    {%- set role = 'model' if message['role'] == 'assistant' else message['role'] -%}
    {%- if role != 'tool' -%}
        {%- if not (role == 'model' and ns.prev_message_type == 'tool_response') -%}
            {{- '<|turn>' + role + '\n' }}
        {%- endif -%}
    {%- endif -%}

    {%- if message['tool_calls'] -%}
        {%- for tool_call in message['tool_calls'] -%}
            {%- set function = tool_call['function'] -%}
            {{- '<|tool_call>call:' + function['name'] + format_argument(function['arguments'], escape_keys=False) + '<tool_call|>' -}}
        {%- endfor -%}
        {%- set ns.prev_message_type = 'tool_call' -%}
    {%- endif -%}

    {%- if role == 'tool' -%}
        {#- Tool Response handling. The model message with the tool calls already
            rendered the first `<|tool_response>`. -#}
        {%- set continues_tool_call = ns.prev_message_type == 'tool_call' -%}
        {%- for item in message['content'] -%}
            {%- if not (loop.first and continues_tool_call) -%}
                {{- '<|tool_response>' -}}
            {%- endif -%}
            {{- 'response:' + item['name'] | default('unknown') -}}
            {%- if item['response'] is mapping -%}
                {{- format_argument(item['response'], escape_keys=False) -}}
            {%- else -%}
                {{- '{value:' + format_argument(item['response'], escape_keys=False) + '}' -}}
            {%- endif -%}
            {{- '<tool_response|>' -}}
        {%- endfor -%}
        {%- set ns.prev_message_type = 'tool_response' -%}
    {%- else -%}
        {{- format_content(message['content']) -}}
        {%- if not message['tool_calls'] -%}
            {%- set ns.prev_message_type = None -%}
        {%- endif -%}
    {%- endif -%}

    {#- Decoding stops on `<|tool_response>` after tool calls and keeps it in the
        KV cache, so it belongs to the model message. -#}
    {%- if role != 'tool' and message['tool_calls'] -%}
        {{- '<|tool_response>' -}}
    {%- endif -%}

    {%- if ns.prev_message_type == None -%}
        {{- '<turn|>\n' -}}
    {%- endif -%}
{%- endfor -%}

{%- if add_generation_prompt -%}
    {%- if ns.prev_message_type != 'tool_response' and ns.prev_message_type != 'tool_call' -%}
        {{- '<|turn>model\n' -}}
    {%- elif ns.prev_message_type == 'tool_response' and thinking -%}
        {{- '<|channel>thought\n' -}}
    {%- endif -%}
{%- endif -%}
''';
