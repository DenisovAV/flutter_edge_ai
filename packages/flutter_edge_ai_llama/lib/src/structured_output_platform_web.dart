import 'dart:js_interop';

import 'package:flutter/foundation.dart' show kIsWasm;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

import 'structured_output_web_policy.dart';

@JS('navigator.userAgent')
external String get _userAgent;

/// Why a response format is refused in this browser for a model loaded on
/// [backend], or null where it has run ([webStructuredOutputRefusal]).
String? structuredOutputHostRefusal(edge.PreferredBackend? backend) =>
    webStructuredOutputRefusal(backend, userAgent: _userAgent, wasm: kIsWasm);
