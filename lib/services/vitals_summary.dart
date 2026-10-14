import '../domain/vitals.dart';

/// Bounded plain-text summary of one profile's recorded readings, for model
/// payloads (health reports, drafts). Readings are listed newest-first with
/// their own dates — never interpolated, averaged, or diagnosed. manual
/// entries are labeled user-reported and unverified; report-linked rows keep
/// their source row reference in the caller, not here.
String vitalsSummaryFor(
  List<VitalEntry> entries,
  String profileId, {
  int maxPerKind = 5,
}) {
  final rows = vitalsFor(entries, profileId);
  if (rows.isEmpty) return '';
  final buffer = StringBuffer(
    'User-recorded readings (user-reported, unverified):',
  );
  for (final kind in VitalKind.values) {
    final series = rows.where((entry) => entry.kind == kind).toList();
    if (series.isEmpty) continue;
    final latest = series.first;
    buffer.write(
      '\n- ${vitalKindLabel(kind)}: latest ${_reading(latest)} '
      'on ${_day(latest.measuredAt)}',
    );
    if (series.length > 1) {
      buffer.write(
        ' (${series.length} readings, '
        '${_date(series.last.measuredAt)}..${_date(series.first.measuredAt)})',
      );
      for (final entry in series.take(maxPerKind).skip(1)) {
        buffer.write('; ${_reading(entry)} on ${_day(entry.measuredAt)}');
      }
      if (series.length > maxPerKind) buffer.write('; …');
    }
  }
  return buffer.toString();
}

String _date(DateTime at) => at.toIso8601String().substring(0, 10);

String _day(DateTime at) =>
    '${at.toIso8601String()} (UTC offset ${at.timeZoneOffset.inMinutes} minutes)';

String _reading(VitalEntry entry) {
  if (entry.kind == VitalKind.bloodPressure) {
    return '${formatVitalValue(entry.value)}/${formatVitalValue(entry.secondaryValue ?? double.nan)}'
        ' ${entry.unit}';
  }
  final glue = entry.unit == '%' ? '' : ' ';
  return '${formatVitalValue(entry.value)}$glue${entry.unit}';
}
