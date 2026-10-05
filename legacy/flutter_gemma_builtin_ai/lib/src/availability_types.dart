/// Public availability types for the built-in OS AI engine.
///
/// Both are aliases of the flutter_local_ai types they used to duplicate. The
/// package that owns the platform code owns the enum; this one adapts it to
/// flutter_gemma, so there is a single set of states to keep in step rather
/// than two that can drift.
///
/// This file used to carry a hard "zero imports" rule, because the native and
/// the web arm each layered their own platform code on top of these types and
/// neither arm could be allowed to pull the other's platform channel into its
/// import graph. Both arms are gone — flutter_local_ai resolves native vs. web
/// behind its own conditional import — so there is nothing left for the rule
/// to protect.
library;

import 'package:flutter_local_ai/flutter_local_ai.dart'
    show LocalAiAvailability, LocalAiUnavailableException;

/// Availability of the OS built-in model, surfaced to app code.
///
/// An alias of [LocalAiAvailability], which declares the same seven values in
/// the same order — so an existing exhaustive `switch` over
/// `BuiltInAiAvailability` keeps compiling unchanged.
///
/// No platform produces all seven. What each backend can actually answer:
///
/// - **Android** (ML Kit GenAI / AICore): `available`, `downloadable`,
///   `downloading`, `unavailableDeviceUnsupported`, `unavailableOther`. ML
///   Kit's `FeatureStatus` has no "too old" or "switched off" state, so those
///   two never appear here.
/// - **iOS / macOS** (Apple Foundation Models): every value except
///   `downloadable` — the OS fetches its own assets, so a model that is not
///   ready yet reports `downloading`, never "you may start a download". Below
///   iOS/macOS 26 the answer is `unavailableOsTooOld`.
/// - **Windows** (AI Foundry / Phi Silica): all seven.
/// - **Web** (Chrome Prompt API): `available`, `downloadable`, `downloading`,
///   `unavailableDeviceUnsupported`, `unavailableOther`. Chrome reports four
///   states and its `'unavailable'` carries no reason, so disk floor, VRAM and
///   a missing origin trial all fold into `unavailableOther`.
///
/// Treat it as a runtime property of the device, never as something the build
/// can guarantee: the same binary answers differently across OS versions.
typedef BuiltInAiAvailability = LocalAiAvailability;

/// Thrown by `BuiltInAi.ensureReady` when the OS/browser model cannot be made
/// ready — device unsupported, OS too old, feature switched off, or an
/// unclassified failure.
///
/// An alias of [LocalAiUnavailableException]; `status` is the terminal
/// availability that caused the failure and `message` explains it.
typedef BuiltInAiUnavailableException = LocalAiUnavailableException;
