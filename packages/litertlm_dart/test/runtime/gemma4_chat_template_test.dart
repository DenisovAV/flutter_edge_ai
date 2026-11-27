// Which prompt template a conversation renders: LiteRT-LM's canonical Gemma 4
// template for the bundles that embed litert-community's older one, the
// bundle's own for every other.
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:litertlm_dart/src/bundle/litertlm_bundle_sampler.dart';
import 'package:litertlm_dart/src/ffi/litert_lm_client.dart';
import 'package:litertlm_dart/src/runtime/gemma4_chat_template.dart';
import 'package:litertlm_dart/src/runtime/types.dart';
import 'package:test/test.dart';

/// `LlmMetadata.jinja_prompt_template` of litert-community's
/// gemma-4-E2B-it.litertlm (sha256 181938…, the catalog's generic E2B), the
/// same bytes as that repository's chat_template.jinja and as the E4B and
/// Intel Lunar Lake E2B bundles embed. See fixtures/README.md.
final _community = File(
  'test/runtime/fixtures/gemma4_litert_community_chat_template.jinja',
).readAsStringSync();

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

void main() {
  test('the fixture is the template the published bundles embed', () {
    expect(_sha(_community), gemma4CommunityTemplateSha256);
  });

  test('the canonical template is LiteRT-LM v0.20.0 (95df4c2a) '
      'models/gemma4/chat_template_e2b_e4b.jinja, byte for byte', () {
    expect(
      _sha(gemma4E2bE4bChatTemplate),
      '5cdb725e75377d5781c44649fcf72da05c3b13eaeb1e559f66b4366042487b5d',
    );
  });

  group('promptTemplateOverrideFor', () {
    test('replaces the community template with the canonical one', () {
      expect(promptTemplateOverrideFor(_community), gemma4E2bE4bChatTemplate);
    });

    test('keeps any other template, a one-byte change included', () {
      expect(promptTemplateOverrideFor(null), isNull);
      expect(promptTemplateOverrideFor('$_community '), isNull);
      expect(promptTemplateOverrideFor(gemma4E2bE4bChatTemplate), isNull);
    });
  });

  group('the client', () {
    test('renders the canonical template for a community bundle', () {
      final client = LiteRtLmFfiClient()
        ..acceptBundleSamplerRead(
          BundleSamplerRead(const BundleSampler(), jinjaTemplate: _community),
        );
      expect(client.promptTemplateOverride, gemma4E2bE4bChatTemplate);
    });

    test('keeps the bundle template otherwise', () {
      for (final read in [
        const BundleSamplerRead(BundleSampler(), jinjaTemplate: '{{ x }}'),
        const BundleSamplerRead(BundleSampler()),
        const BundleSamplerRead.failed('FormatException: truncated'),
      ]) {
        final client = LiteRtLmFfiClient()..acceptBundleSamplerRead(read);
        expect(client.promptTemplateOverride, isNull);
      }
    });
  });
}
