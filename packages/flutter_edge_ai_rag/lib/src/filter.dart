/// Payload filter applied alongside vector similarity search.
///
/// Conditions in [must] are ANDed, conditions in [should] are ORed, and
/// documents matching any [mustNot] condition are excluded. Backends ignore
/// conditions for fields that are not declared in the store's [FilterSchema].
class Filter {
  const Filter({this.must, this.should, this.mustNot});

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
  const FieldEquals({required this.key, required this.value})
    : assert(
        value is String || value is num || value is bool,
        'FieldEquals.value must be String, num, or bool',
      );

  @override
  final String key;
  final Object value;
}

/// Inclusive numeric range against a metadata field.
class FieldRange extends Condition {
  const FieldRange({required this.key, this.gte, this.lte})
    : assert(
        gte == null ||
            gte != double.infinity &&
                gte != double.negativeInfinity &&
                gte == gte,
        'FieldRange.gte must be finite',
      ),
      assert(
        lte == null ||
            lte != double.infinity &&
                lte != double.negativeInfinity &&
                lte == lte,
        'FieldRange.lte must be finite',
      );

  @override
  final String key;
  final double? gte;
  final double? lte;
}

/// Set-membership predicate against a metadata field.
class FieldMatchAny extends Condition {
  const FieldMatchAny({required this.key, required this.values});

  @override
  final String key;
  final List<Object> values;
}

enum FilterFieldType { string, number, bool }

/// A metadata field promoted to a backend-native filterable field.
class FilterField {
  const FilterField({required this.name, required this.type})
    : assert(name != '', 'FilterField.name must not be empty');

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
  const FilterSchema({this.fields = const []});

  final List<FilterField> fields;

  bool get isEmpty => fields.isEmpty;

  FilterField? fieldFor(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }
}
