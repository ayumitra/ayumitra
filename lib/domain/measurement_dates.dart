/// Measurement dates are patient calendar dates. A birth time is not required,
/// so a reading on the birth day is valid even when its clock time is midnight.
void validateMeasurementDate(
  DateTime measuredAt, {
  DateTime? dateOfBirth,
  DateTime? now,
}) {
  DateTime day(DateTime at) => DateTime.utc(at.year, at.month, at.day);
  if (dateOfBirth != null && day(measuredAt).isBefore(day(dateOfBirth))) {
    throw const FormatException('Date cannot be before the date of birth.');
  }
  if (measuredAt.isAfter(now ?? DateTime.now())) {
    throw const FormatException('A measurement cannot be dated in the future.');
  }
}

/// Model tool dates must be unambiguous and real. DateTime.parse alone silently
/// rolls dates such as February 30 into another month and must not authorize a
/// medical-record write.
DateTime parseMeasurementDay(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  if (match == null) throw const FormatException('Use a YYYY-MM-DD date.');
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final result = DateTime(year, month, day);
  if (year < 1 ||
      result.year != year ||
      result.month != month ||
      result.day != day) {
    throw const FormatException('Use a real YYYY-MM-DD calendar date.');
  }
  return result;
}
