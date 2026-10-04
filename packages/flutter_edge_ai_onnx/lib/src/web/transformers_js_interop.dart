// `dart:js_interop` binding to Transformers.js v4 (`@huggingface/transformers`)
// — the web text-generation arm (ONNX web PR, `feat/onnx-web`). Mirrors
// `ort_web_client.dart`'s style: extension types over `JSObject`, `@JS()`
// static interop, a `window.transformersReady` readiness handshake (see
// `example/web/index.html`) — same shape as `window.ortReady` /
// `window.litertLmReady`.
//
// Divergence from `onnxruntime-web` (the embedding arm's binding):
// Transformers.js owns the WHOLE pipeline — tokenization, chat templating,
// the generation loop, the KV cache — behind one `pipeline()` call. There is
// no `InferenceSession` / `Tensor` plumbing here; the caller
// (`onnx_web_inference_model.dart`) only drives `pipe(messages, options)`
// plus a [TextStreamer] for incremental output and an
// [InterruptableStoppingCriteria] for cancellation.
//
// `dart:js_interop` only resolves on web compile targets — this file can
// never be imported into a VM (`flutter test`) run; it is compile-checked
// by `flutter build web` and exercised for real only in a browser.
@JS()
library;

import 'dart:js_interop';

/// `window.transformersReady` — a Promise that resolves once
/// `window.transformers` is set (see `example/web/index.html`'s ESM shim).
@JS('transformersReady')
external JSPromise<JSAny?> get transformersReady;

/// `window.transformers` — the resolved `@huggingface/transformers` ESM
/// module namespace.
@JS('transformers')
external TransformersNamespace get transformers;

/// `window.transformers` namespace surface used by the web text-generation
/// arm.
extension type TransformersNamespace._(JSObject _) implements JSObject {
  /// `pipeline(task, model, options)` — returns a Promise of a callable
  /// pipeline object, typed as [TransformersPipeline] (see there for why it
  /// is not a [JSFunction]). `task` is always `'text-generation'` here;
  /// `model` is the Hugging Face repo id (see `TransformersWebResolver`).
  external JSPromise<TransformersPipeline> pipeline(
    JSString task,
    JSString model,
    JSObject? options,
  );

  /// Global runtime config (`allowRemoteModels`, `useBrowserCache`,
  /// `backends.onnx.wasm.wasmPaths`, …) — configured once by
  /// `example/web/index.html`'s ESM shim; not touched from Dart in v1.
  external JSObject get env;
}

/// A Transformers.js `PreTrainedTokenizer` — the pipeline's own
/// `pipe.tokenizer`. It is callable (`tokenizer(text) -> {input_ids: Tensor,
/// attention_mask: Tensor}`), but the caller only needs [encode] and to hand
/// the object to [TextStreamer]. Like the pipeline it is a `Callable` with a
/// swapped prototype, so if it ever has to be CALLED, go through
/// `Reflect.apply` as [TransformersPipeline.generate] does — never
/// `callAsFunction`.
extension type TransformersTokenizer._(JSObject _) implements JSObject {
  /// `tokenizer.encode(text)` -> a plain `number[]` of token ids, whose
  /// `.length` is the exact token count. NB: calling the tokenizer as a
  /// FUNCTION instead returns `{input_ids: Tensor[1, seq], ...}` whose
  /// `input_ids` is a Tensor with NO `.length` — reading `.length` off it
  /// yields `undefined`, which is why token counting goes through `encode`.
  external JSArray<JSNumber> encode(JSString text);
}

/// `new transformers.TextStreamer(tokenizer, options)` — invokes
/// `options.callback_function` synchronously for every newly decoded chunk
/// of text (`{ skip_prompt: true, skip_special_tokens: true,
/// callback_function: (text) => ... }`). `tokenizer` is the pipeline's own
/// `pipe.tokenizer` (a [TransformersTokenizer], passed here as its
/// [JSObject] supertype).
@JS('transformers.TextStreamer')
extension type TextStreamer._(JSObject _) implements JSObject {
  external factory TextStreamer(JSObject tokenizer, JSObject options);
}

/// `new transformers.InterruptableStoppingCriteria()` — passed as
/// `stopping_criteria` in the generation call options; `.interrupt()` stops
/// decoding at the next token boundary (checked between forward passes, so
/// it is not instantaneous — the same posture every other engine's
/// `stopGeneration()` has).
@JS('transformers.InterruptableStoppingCriteria')
extension type InterruptableStoppingCriteria._(JSObject _) implements JSObject {
  external factory InterruptableStoppingCriteria();

  external void interrupt();
  external void reset();
}

/// A Transformers.js text-generation pipeline — the value `pipeline()`
/// resolves to.
///
/// At runtime it is a function object, but typed as a [JSObject] on purpose:
/// Transformers.js builds it through its `Callable` base, a closure whose
/// prototype is swapped to `Pipeline.prototype`, so it has no
/// `Function.prototype.call`. `callAsFunction` compiles to `target.call(...)`
/// and throws "tried to call a non-function" — which broke every web
/// generation until 0.5.1. Not implementing [JSFunction] keeps that call from
/// compiling; [generate] goes through `Reflect.apply`, which needs only the
/// object's internal `[[Call]]`.
extension type TransformersPipeline._(JSObject _) implements JSObject {
  /// `pipe.tokenizer`.
  external TransformersTokenizer get tokenizer;

  /// `pipe(messages, options)` — resolves once generation finishes; chunks
  /// arrive earlier through the `streamer` in [options].
  JSPromise<JSAny?> generate(JSAny? messages, JSObject options) =>
      _reflectApply(this, null, [messages, options].toJS) as JSPromise<JSAny?>;
}

@JS('Reflect.apply')
external JSAny? _reflectApply(
  JSObject target,
  JSAny? thisArg,
  JSArray<JSAny?> args,
);
