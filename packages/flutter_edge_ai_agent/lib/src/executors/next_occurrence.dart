/// The local [DateTime] a reminder at [hour]:[minute] is for: on the explicit
/// date when [year], [month] and [day] are all given, otherwise today, or
/// tomorrow once that time has passed ([now] defaults to the current time).
///
/// Tomorrow is the next calendar day at the same wall-clock time, not 24 hours
/// later: on a night the clocks change, 24 hours after 08:00 is 07:00 or 09:00.
DateTime nextOccurrence({
  required int hour,
  required int minute,
  int? year,
  int? month,
  int? day,
  DateTime? now,
}) {
  if (year != null && month != null && day != null) {
    return DateTime(year, month, day, hour, minute);
  }
  final current = now ?? DateTime.now();
  final today = DateTime(
    current.year,
    current.month,
    current.day,
    hour,
    minute,
  );
  if (today.isAfter(current)) return today;
  return DateTime(current.year, current.month, current.day + 1, hour, minute);
}
