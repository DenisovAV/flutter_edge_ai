import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _activeModelParamsTests();

  test('carries the resolved modelPath and optional tokenizerPath', () {
    const c = RuntimeConfig(
      maxTokens: 512,
      modelPath: '/tmp/m.litertlm',
      tokenizerPath: '/tmp/tok.json',
    );
    expect(c.modelPath, '/tmp/m.litertlm');
    expect(c.tokenizerPath, '/tmp/tok.json');
  });

  test('tokenizerPath defaults to null for inference', () {
    const c = RuntimeConfig(maxTokens: 256, modelPath: '/m');
    expect(c.tokenizerPath, isNull);
  });
}

void _activeModelParamsTests() {
  group('ActiveModelParams.firstDifference', () {
    const base = ActiveModelParams(maxTokens: 1024);

    test('identical params reuse the cached model', () {
      expect(
        base.firstDifference(const ActiveModelParams(maxTokens: 1024)),
        isNull,
      );
    });

    test('names the differing parameter, not just "changed"', () {
      // The whole point: a caller who asks for CPU after a GPU build used to
      // get the GPU model in silence. The name is what makes the log
      // actionable — "paramsChanged=true" tells nobody what to change.
      expect(
        base.firstDifference(
          const ActiveModelParams(
            maxTokens: 1024,
            preferredBackend: PreferredBackend.cpu,
          ),
        ),
        'preferredBackend',
      );
    });

    test('covers every parameter getActiveModel accepts', () {
      // Desktop compared three of these and mobile compared none, so the rest
      // were silently ignored on reuse. Each must force a rebuild.
      //
      // Each case is a PAIR, not a single variant against a shared base:
      // _rawDifference returns the FIRST difference, and maxNumImages only
      // means anything when supportImage is on. Comparing a vision-on variant
      // against a vision-off base would report 'supportImage' and the
      // maxNumImages case would pass without ever exercising maxNumImages.
      final cases = <String, (ActiveModelParams, ActiveModelParams)>{
        'maxTokens': (base, const ActiveModelParams(maxTokens: 4096)),
        'preferredBackend': (
          base,
          const ActiveModelParams(
            maxTokens: 1024,
            preferredBackend: PreferredBackend.gpu,
          ),
        ),
        'preferredVisionBackend': (
          base,
          const ActiveModelParams(
            maxTokens: 1024,
            preferredVisionBackend: PreferredBackend.gpu,
          ),
        ),
        'preferredAudioBackend': (
          base,
          const ActiveModelParams(
            maxTokens: 1024,
            preferredAudioBackend: PreferredBackend.gpu,
          ),
        ),
        'supportImage': (
          base,
          const ActiveModelParams(maxTokens: 1024, supportImage: true),
        ),
        'supportAudio': (
          base,
          const ActiveModelParams(maxTokens: 1024, supportAudio: true),
        ),
        'maxNumImages': (
          const ActiveModelParams(maxTokens: 1024, supportImage: true),
          const ActiveModelParams(
            maxTokens: 1024,
            supportImage: true,
            maxNumImages: 4,
          ),
        ),
        'enableSpeculativeDecoding': (
          base,
          const ActiveModelParams(
            maxTokens: 1024,
            enableSpeculativeDecoding: true,
          ),
        ),
        'activationDataType': (
          base,
          const ActiveModelParams(
            maxTokens: 1024,
            activationDataType: ActivationDataType.float32,
          ),
        ),
        'maxConcurrentSessions': (
          base,
          const ActiveModelParams(maxTokens: 1024, maxConcurrentSessions: 2),
        ),
        'loraRanks': (
          base,
          const ActiveModelParams(maxTokens: 1024, loraRanks: [4, 8]),
        ),
      };
      for (final entry in cases.entries) {
        final (from, to) = entry.value;
        expect(
          from.firstDifference(to),
          entry.key,
          reason: '${entry.key} must force a rebuild',
        );
      }

      // NOT `expect(cases.length, 10)`. That assertion runs backwards: whoever
      // adds an eleventh knob and forgets this map leaves the length at ten
      // and the suite green, while whoever DOES add a case has to edit an
      // unrelated literal to make it pass. It is noisy for the careful and
      // silent for the careless — the exact inversion of what a test is for.
      // loraRanks was the live proof: a real createModel knob, uncompared,
      // under a count that read "nine" and passed.
      //
      // Assert the property instead: every field the class compares must have
      // a case here. The names come from _rawDifference itself via a param
      // that differs in EVERY field, walked one repair at a time — so a new
      // comparison with no case makes this fail, naming the missing knob.
      const everythingElse = ActiveModelParams(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.gpu,
        preferredVisionBackend: PreferredBackend.gpu,
        preferredAudioBackend: PreferredBackend.gpu,
        supportImage: true,
        supportAudio: true,
        maxNumImages: 7,
        enableSpeculativeDecoding: true,
        activationDataType: ActivationDataType.float32,
        maxConcurrentSessions: 3,
        loraRanks: [4, 8],
      );
      expect(
        base.firstDifference(everythingElse),
        isNotNull,
        reason: 'sanity: the two differ',
      );
      final compared = <String>{};
      var probe = base;
      while (true) {
        final name = probe.firstDifference(everythingElse);
        if (name == null) break;
        expect(compared.add(name), isTrue, reason: '$name reported twice');
        probe = _repair(probe, everythingElse, name);
      }
      expect(
        compared.difference(cases.keys.toSet()),
        isEmpty,
        reason: 'ActiveModelParams compares a knob with no case above',
      );
    });

    test('values the engines normalise away do not force a rebuild', () {
      // A rebuild unloads and reloads multi-gigabyte weights, so comparing the
      // RAW request is not enough. Both engines apply `maxNumImages ?? 1` when
      // vision is on and drop it when vision is off, and a null encoder
      // backend reaches native as CPU. Two requests that build a
      // bit-identical engine must compare equal, or every caller that spells
      // a default explicitly pays for a reload that changes nothing.
      expect(
        const ActiveModelParams(
          maxTokens: 1024,
          supportImage: true,
        ).firstDifference(
          const ActiveModelParams(
            maxTokens: 1024,
            supportImage: true,
            maxNumImages: 1,
          ),
        ),
        isNull,
        reason: 'maxNumImages defaults to 1 when vision is on',
      );

      expect(
        base.firstDifference(
          const ActiveModelParams(maxTokens: 1024, maxNumImages: 4),
        ),
        isNull,
        reason: 'maxNumImages is not sent at all when vision is off',
      );

      expect(
        base.firstDifference(
          const ActiveModelParams(
            maxTokens: 1024,
            preferredVisionBackend: PreferredBackend.cpu,
            preferredAudioBackend: PreferredBackend.cpu,
          ),
        ),
        isNull,
        reason: 'a null encoder backend is CPU',
      );
    });
  });
}

/// Copy [probe] with the single field [name] taken from [target].
///
/// Used to walk _rawDifference one repair at a time and collect the names of
/// every field it actually compares. Spelled out rather than routed through a
/// copyWith: ActiveModelParams has nullable fields, and a copyWith cannot set
/// one back to null without a sentinel — not worth adding to the public API
/// for a test helper.
ActiveModelParams _repair(
  ActiveModelParams probe,
  ActiveModelParams target,
  String name,
) {
  const known = {
    'maxTokens',
    'preferredBackend',
    'preferredVisionBackend',
    'preferredAudioBackend',
    'supportImage',
    'supportAudio',
    'maxNumImages',
    'enableSpeculativeDecoding',
    'activationDataType',
    'maxConcurrentSessions',
    'loraRanks',
  };
  // A knob _rawDifference compares that this file has never heard of. Throwing
  // is the point: without it the walk below would spin forever on a name it
  // cannot repair.
  if (!known.contains(name)) {
    throw StateError('no repair for "$name" — add one when adding a knob');
  }
  bool is_(String f) => name == f;
  return ActiveModelParams(
    maxTokens: is_('maxTokens') ? target.maxTokens : probe.maxTokens,
    preferredBackend: is_('preferredBackend')
        ? target.preferredBackend
        : probe.preferredBackend,
    preferredVisionBackend: is_('preferredVisionBackend')
        ? target.preferredVisionBackend
        : probe.preferredVisionBackend,
    preferredAudioBackend: is_('preferredAudioBackend')
        ? target.preferredAudioBackend
        : probe.preferredAudioBackend,
    supportImage: is_('supportImage')
        ? target.supportImage
        : probe.supportImage,
    supportAudio: is_('supportAudio')
        ? target.supportAudio
        : probe.supportAudio,
    maxNumImages: is_('maxNumImages')
        ? target.maxNumImages
        : probe.maxNumImages,
    enableSpeculativeDecoding: is_('enableSpeculativeDecoding')
        ? target.enableSpeculativeDecoding
        : probe.enableSpeculativeDecoding,
    activationDataType: is_('activationDataType')
        ? target.activationDataType
        : probe.activationDataType,
    maxConcurrentSessions: is_('maxConcurrentSessions')
        ? target.maxConcurrentSessions
        : probe.maxConcurrentSessions,
    loraRanks: is_('loraRanks') ? target.loraRanks : probe.loraRanks,
  );
}
