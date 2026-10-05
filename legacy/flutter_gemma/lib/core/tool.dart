class Tool {
  const Tool({
    required this.name,
    required this.description,
    this.parameters = const {},
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

/// Controls whether the model should call tools.
enum ToolChoice {
  /// Model decides whether to call a tool (default).
  auto,

  /// Model must respond with a function call.
  ///
  /// Not supported by FunctionGemma: its prompt format has no way
  /// to express the constraint, so it behaves as [auto] and logs a warning.
  required,

  /// Model must NOT call any tools, even if tools are provided.
  none,
}
