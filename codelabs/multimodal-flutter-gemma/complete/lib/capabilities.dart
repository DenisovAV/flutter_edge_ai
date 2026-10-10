import 'package:flutter/foundation.dart' show kIsWeb;

import 'model.dart';

/// One modality, answered from BOTH sides.
///
/// A model that accepts audio does not mean this platform will deliver it,
/// and a platform that can record does not mean the model can hear. So the
/// app asks both questions, and — when the answer is no — says which one said
/// it. A single `bool canSendAudio` cannot do that: it collapses two
/// independent facts into one, and the user is left staring at a greyed-out
/// microphone with no idea whether the app is broken, the model is wrong, or
/// this is simply not a place where audio works.
///
/// Two questions, not every question. A third axis — this particular device,
/// and what its memory and hardware will actually stand — is deliberately out
/// of scope: an old phone or an iOS Simulator answers yes to both of these and
/// can still crawl or run out of memory, and the app finds that out from a load
/// error instead. A fourth (the microphone permission) is asked at the moment
/// of use in `chat_page.dart`, because unlike these two it can change while the
/// app is running. Copy this type by all means — but do not read it as the
/// complete list of reasons a modality can fail.
class Capability {
  const Capability({
    required this.what,
    required this.byModel,
    required this.byPlatform,
    required this.modelReason,
    required this.platformReason,
  });

  /// How this modality is named to the user: "Image input", "Audio input".
  ///
  /// It lives on the value rather than travelling beside it, so that a caller
  /// cannot pair one modality's label with another modality's answer — a
  /// confident, fluent sentence about something that never happened, which is
  /// the failure this whole codelab is written against. The two factories below
  /// are the only things that set it, and each knows which modality it is.
  final String what;

  /// Can the weights take this input at all?
  final bool byModel;

  /// Will this platform actually carry it to them?
  final bool byPlatform;

  /// Why [byModel] is false. Read only when it is.
  final String modelReason;

  /// Why [byPlatform] is false. Read only when it is.
  final String platformReason;

  bool get available => byModel && byPlatform;

  /// Which side said no, and why. Null when both said yes.
  ///
  /// Both can refuse at once — a text-only model in a browser — and then the
  /// user deserves both halves, because fixing one changes nothing.
  String? get blockedBecause => switch ((byModel, byPlatform)) {
    (true, true) => null,
    (false, true) => modelReason,
    (true, false) => platformReason,
    (false, false) => '$modelReason, and $platformReason',
  };
}

/// What the platform will carry, before any model is involved.
///
/// This is the half of the question a model cannot answer for you. It is the
/// only half that says no to THIS model — Gemma 4 E2B has both encoders
/// everywhere it runs — but not the only half that ever says no: hand these
/// same factories Step 2's SmolVLM2 and `audioCapability` refuses from the
/// model side, on a phone whose microphone was never in question. Two
/// different failures, and the app that greys out one button for both of them
/// has told the user nothing.
abstract final class PlatformSupport {
  /// Image input reaches the model on all five native platforms — Android,
  /// iOS, macOS, Windows and Linux.
  ///
  /// Not on the web: `flutter_edge_ai_litertlm`'s browser arm runs the upstream
  /// `@litert-lm/core` package, whose JS API exposes no vision executor, so a
  /// message carrying an image **throws `UnsupportedError`** when it is sent.
  /// The refusal is honest, but it comes late — after the user has picked the
  /// photo and typed the question — which is exactly why the app asks this
  /// before it offers the button.
  static bool get image => !kIsWeb;

  static const imageBlockedReason =
      'this platform has no image input '
      '(the browser runtime exposes no vision executor)';

  /// Audio input works on Android, on a real iPhone or iPad, and on all three
  /// desktops through the `.litertlm` engine. Not on the web, for the same
  /// reason images are not: the browser runtime exposes no audio executor
  /// either, and a clip throws the same way, after the user has recorded it.
  ///
  /// The iOS **Simulator** is the case this flag deliberately does not try to
  /// cover, and the reason is not that it cannot be detected — `device_info_plus`
  /// exposes `IosDeviceInfo.isPhysicalDevice` for exactly this. It is that the
  /// Simulator is a *supported* configuration, not a refused one: the SDK runs
  /// it CPU-only, because Metal's simulator implementation caps a single
  /// allocation at 256 MB, well under this model's weights. So a 2.59 GB model
  /// there will crawl if it loads at all — which is a hardware answer, not a
  /// platform one, and it belongs to the axis this type says it does not model.
  /// The app finds it out the honest way, from the microphone probe in
  /// `chat_page.dart` or from a load error.
  static bool get audio => !kIsWeb;

  static const audioBlockedReason =
      'this platform has no audio input '
      '(the browser runtime exposes no audio executor)';
}

/// Can this app send an image right now, with this model, on this device?
Capability imageCapability(ModelChoice model) => Capability(
  what: 'Image input',
  byModel: model.supportsImage,
  byPlatform: PlatformSupport.image,
  modelReason: '${model.label} has no vision encoder',
  platformReason: PlatformSupport.imageBlockedReason,
);

/// Can this app send a recording right now, with this model, on this device?
Capability audioCapability(ModelChoice model) => Capability(
  what: 'Audio input',
  byModel: model.supportsAudio,
  byPlatform: PlatformSupport.audio,
  modelReason: '${model.label} has no audio encoder',
  platformReason: PlatformSupport.audioBlockedReason,
);
