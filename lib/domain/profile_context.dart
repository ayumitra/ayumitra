import 'records.dart';
import 'vitals.dart';

/// A small, dated profile reference for each model role. It contains no name,
/// internal profile id, history, inferred birth date or inferred measurements.
/// All measurements retain their stored numeric precision and units.
Map<String, dynamic> buildProfileContext(
  Profile owner,
  List<VitalEntry> readings, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final today = _day(current);
  final suppliedBirth = owner.dateOfBirth;
  final birth = suppliedBirth == null ? null : _day(suppliedBirth);
  final validBirth = birth != null && !birth.isAfter(today) ? birth : null;

  Map<String, dynamic>? latest(VitalKind kind) {
    VitalEntry? selected;
    for (final reading in readings) {
      if (reading.profileId != owner.id ||
          reading.kind != kind ||
          !_validCurrentMeasurement(reading) ||
          reading.measuredAt.isAfter(current) ||
          (validBirth != null &&
              _day(reading.measuredAt).isBefore(validBirth))) {
        continue;
      }
      if (selected == null || reading.measuredAt.isAfter(selected.measuredAt)) {
        selected = reading;
      }
    }
    if (selected == null) return null;
    return {
      'value': selected.value,
      'unit': selected.unit,
      'measuredAt': selected.measuredAt.toIso8601String(),
      'source': selected.source,
      'sourceId': 'vitals',
    };
  }

  return {
    'dateOfBirth': validBirth == null ? null : _isoDay(validBirth),
    'ageLabel': currentAgeLabel(owner, now: current),
    'exactAge': validBirth == null ? null : _calendarAge(validBirth, today),
    'currentWeight': latest(VitalKind.weight),
    'currentHeight': latest(VitalKind.height),
    'currentDateTime': current.toIso8601String(),
    'timeZoneOffsetMinutes': current.timeZoneOffset.inMinutes,
  };
}

/// Recheck persisted anthropometric data without consulting the wall clock or
/// rounding a stored value. This helper has no report collection: a report
/// reading must name an evidence row, while ownership/existence of that row
/// remains the caller's report-boundary check.
bool _validCurrentMeasurement(VitalEntry reading) {
  if (reading.id.trim().isEmpty ||
      reading.profileId.trim().isEmpty ||
      !reading.value.isFinite ||
      reading.value < 0 ||
      reading.secondaryValue != null ||
      reading.unit != defaultVitalUnit(reading.kind)) {
    return false;
  }
  final max = switch (reading.kind) {
    VitalKind.height => 300.0,
    VitalKind.weight => 1000.0,
    _ => null,
  };
  if (max == null || reading.value > max) return false;
  final rounded = (reading.value * 1000).roundToDouble() / 1000;
  if ((reading.value - rounded).abs() >= 1e-9) return false;
  if (reading.source == 'user') return true;
  return reading.source == 'report' &&
      reading.sourceLineId != null &&
      reading.sourceLineId!.trim().isNotEmpty;
}

DateTime _day(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

String _isoDay(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

Map<String, int> _calendarAge(DateTime birth, DateTime today) {
  // Match currentAgeLabel's completed-month rule. In non-leap years, a
  // February 29 birth completes its annual birthday on March 1.
  var completedMonths =
      (today.year - birth.year) * 12 + today.month - birth.month;
  if (today.day < birth.day) completedMonths--;
  if (completedMonths < 0) completedMonths = 0;
  final targetMonth = birth.month + completedMonths;
  final first = DateTime.utc(birth.year, targetMonth);
  final lastDay = DateTime.utc(first.year, first.month + 1, 0).day;
  final leapAnniversary =
      birth.month == 2 &&
      birth.day == 29 &&
      first.month == 2 &&
      lastDay == 28 &&
      completedMonths % 12 == 0;
  final anchor = leapAnniversary
      ? DateTime.utc(first.year, 3, 1)
      : DateTime.utc(
          first.year,
          first.month,
          birth.day > lastDay ? lastDay : birth.day,
        );
  final remainingDays = today.difference(anchor).inDays;
  return {
    'years': completedMonths ~/ 12,
    'months': completedMonths % 12,
    'days': remainingDays < 0 ? 0 : remainingDays,
  };
}
