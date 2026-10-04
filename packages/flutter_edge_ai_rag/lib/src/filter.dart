/// Payload filter applied alongside vector similarity search.
///
/// Conditions in [must] are ANDed, conditions in [should] are ORed, and
/// documents matching any [mustNot] condition are excluded. Backends ignore
/// conditions for fields that are not declared in the store's [FilterSchema].
class Filter {
  Filter({
    List<Condition>? must,
    List<Condition>? should,
    List<Condition>? mustNot,
  }) : must = _snapshotNullable(must),
       should = _snapshotNullable(should),
       mustNot = _snapshotNullable(mustNot);

  final List<Condition>? must;
  final List<Condition>? should;
  final List<Condition>? mustNot;

  bool get isEmpty =>
      (must == null || must!.isEmpty) &&
      (should == null || should!.isEmpty) &&
      (mustNot == null || mustNot!.isEmpty);
}

/// A predicate over one metadata field.
sealed class Condition {
  const Condition();

  String get key;
}

/// Exact scalar equality against a metadata field.
class FieldEquals extends Condition {
  FieldEquals({required this.key, required this.value}) {
    _validateKey(key);
    _validateScalar(value, 'value');
  }

  @override
  final String key;
  final Object value;
}

/// Inclusive numeric range against a metadata field.
class FieldRange extends Condition {
  FieldRange({required this.key, this.gte, this.lte}) {
    _validateKey(key);
    _validateFinite(gte, 'gte');
    _validateFinite(lte, 'lte');
  }

  @override
  final String key;
  final double? gte;
  final double? lte;
}

/// Set-membership predicate against a metadata field.
class FieldMatchAny extends Condition {
  FieldMatchAny({required this.key, required List<Object> values})
    : values = List<Object>.unmodifiable(values) {
    _validateKey(key);
    for (final value in values) {
      _validateScalar(value, 'values');
    }
  }

  @override
  final String key;
  final List<Object> values;
}

enum FilterFieldType { string, number, bool }

/// A metadata field promoted to a backend-native filterable field.
class FilterField {
  FilterField({required this.name, required this.type}) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
  }

  final String name;
  final FilterFieldType type;

  /// Validates the backend-independent schema invariants in release builds.
  static void validateSchema(FilterSchema schema) {
    final seen = <String>{};
    for (final field in schema.fields) {
      if (field.name.trim().isEmpty) {
        throw ArgumentError.value(
          field.name,
          'FilterField.name',
          'must not be empty',
        );
      }
      if (!seen.add(field.name)) {
        throw ArgumentError.value(
          field.name,
          'FilterSchema.fields',
          'duplicate filter field name',
        );
      }
    }
  }
}

/// Metadata fields a vector store should make filterable.
class FilterSchema {
  FilterSchema({List<FilterField> fields = const []})
    : fields = List<FilterField>.unmodifiable(fields);

  const FilterSchema._empty() : fields = const [];

  static const empty = FilterSchema._empty();

  final List<FilterField> fields;

  bool get isEmpty => fields.isEmpty;

  FilterField? fieldFor(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }
}

List<T>? _snapshotNullable<T>(List<T>? values) =>
    values == null ? null : List<T>.unmodifiable(values);

void _validateKey(String key) {
  if (key.trim().isEmpty) {
    throw ArgumentError.value(key, 'key', 'must not be empty');
  }
}

void _validateScalar(Object value, String name) {
  if (value is! String && value is! num && value is! bool) {
    throw ArgumentError.value(value, name, 'must be String, num, or bool');
  }
  if (value is num && !value.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}

void _validateFinite(double? value, String name) {
  if (value != null && !value.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}
