/// Local-first key-metric tracking: pulse oximetry, blood pressure,
/// temperature, pulse, height, and weight, with trend-ready ordering.
///
/// Entries are user-recorded or report-linked, never inferred. A blood
/// pressure reading carries systolic in [value] and diastolic in
/// [secondaryValue]; every other kind uses [value] alone. Units travel with
/// the entry so °C/°F and mmHg/%/bpm mixes can never be misread downstream.
library;

import 'dart:convert';

typedef VitalJson = Map<String, dynamic>;

/// Matches planner/user wording to a metric kind. Null when unknown — the
/// caller asks for clarification instead of recording under a guessed kind.
VitalKind? parseVitalKind(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'spo2':
    case 'spo₂':
    case 'oxygen':
    case 'oxygen saturation':
    case 'o2 saturation':
    case 'o2 sat':
      return VitalKind.spo2;
    case 'bloodpressure':
    case 'blood pressure':
    case 'bp':
      return VitalKind.bloodPressure;
    case 'temperature':
    case 'temp':
      return VitalKind.temperature;
    case 'pulse':
    case 'heart rate':
    case 'heartrate':
      return VitalKind.pulse;
    case 'height':
    case 'stature':
      return VitalKind.height;
    case 'weight':
    case 'mass':
      return VitalKind.weight;
  }
  return null;
}

/// Normalizes a caller-supplied unit to the exact stored unit, or null when
/// it is not a known spelling. Never guesses across units.
String? normalizeVitalUnit(VitalKind kind, String? raw) {
  if (raw == null) return defaultVitalUnit(kind);
  final unit = raw.trim().toLowerCase();
  switch (kind) {
    case VitalKind.spo2:
      return unit == '%' ? '%' : null;
    case VitalKind.bloodPressure:
      return unit == 'mmhg' ? 'mmHg' : null;
    case VitalKind.temperature:
      if (unit == '°c' || unit == 'c' || unit == 'celsius') return '°C';
      if (unit == '°f' || unit == 'f' || unit == 'fahrenheit') return '°F';
      return null;
    case VitalKind.pulse:
      return unit == 'bpm' ? 'bpm' : null;
    case VitalKind.height:
      if (unit == 'cm' || unit == 'centimeter' || unit == 'centimeters') {
        return 'cm';
      }
      return null;
    case VitalKind.weight:
      if (unit == 'kg' ||
          unit == 'kilo' ||
          unit == 'kilos' ||
          unit == 'kilogram' ||
          unit == 'kilograms') {
        return 'kg';
      }
      return null;
  }
}

/// A planner `record_metric` request: metric type, numeric value, and the
/// optional diastolic/unit/date/note. Parsed strictly — malformed payloads
/// return null so the planner repairs instead of recording a guess.
class MetricRequest {
  const MetricRequest({
    required this.kind,
    required this.value,
    this.secondary,
    this.unit,
    this.date,
    this.note = '',
  });
  final VitalKind kind;
  final double value;
  final double? secondary;
  final String? unit;
  final String? date;
  final String note;
}

MetricRequest? parseMetricRequest(String query) {
  try {
    final map = jsonDecode(query.trim());
    if (map is! Map) return null;
    final kind = map['kind'] is String
        ? parseVitalKind(map['kind'] as String)
        : null;
    if (kind == null) return null;
    final rawValue = map['value'];
    final value = rawValue is int
        ? rawValue.toDouble()
        : rawValue is double
        ? rawValue
        : null;
    if (value == null || !value.isFinite) return null;
    double? secondary;
    if (map.containsKey('secondary') && map['secondary'] != null) {
      final raw = map['secondary'];
      secondary = raw is int
          ? raw.toDouble()
          : raw is double
          ? raw
          : null;
      if (secondary == null || !secondary.isFinite) return null;
    }
    final unit = map['unit'];
    if (unit != null && unit is! String) return null;
    final date = map['date'];
    if (date != null && date is! String) return null;
    final note = map['note'];
    if (note != null && note is! String) return null;
    return MetricRequest(
      kind: kind,
      value: value,
      secondary: secondary,
      unit: unit as String?,
      date: date as String?,
      note: (note as String?) ?? '',
    );
  } catch (_) {
    return null;
  }
}

enum VitalKind { spo2, bloodPressure, temperature, pulse, height, weight }

/// Default display unit per kind. Callers may store °F explicitly instead;
/// range checks below accept both Celsius and Fahrenheit temperatures.
String defaultVitalUnit(VitalKind kind) => switch (kind) {
  VitalKind.spo2 => '%',
  VitalKind.bloodPressure => 'mmHg',
  VitalKind.temperature => '°C',
  VitalKind.pulse => 'bpm',
  VitalKind.height => 'cm',
  VitalKind.weight => 'kg',
};

String vitalKindLabel(VitalKind kind) => switch (kind) {
  VitalKind.spo2 => 'Oxygen saturation',
  VitalKind.bloodPressure => 'Blood pressure',
  VitalKind.temperature => 'Temperature',
  VitalKind.pulse => 'Pulse',
  VitalKind.height => 'Height',
  VitalKind.weight => 'Weight',
};

class VitalEntry {
  const VitalEntry({
    required this.id,
    required this.profileId,
    required this.kind,
    required this.value,
    this.secondaryValue,
    required this.unit,
    required this.measuredAt,
    this.source = 'user',
    this.sourceLineId,
    this.note = '',
  });
  final String id, profileId, unit, source;
  final VitalKind kind;
  final double value;
  final double? secondaryValue;
  final DateTime measuredAt;
  final String? sourceLineId;
  final String note;

  VitalEntry copy({
    String? id,
    String? profileId,
    VitalKind? kind,
    double? value,
    double? secondaryValue,
    bool clearSecondary = false,
    String? unit,
    DateTime? measuredAt,
    String? source,
    String? sourceLineId,
    bool clearSourceLine = false,
    String? note,
  }) => VitalEntry(
    id: id ?? this.id,
    profileId: profileId ?? this.profileId,
    kind: kind ?? this.kind,
    value: value ?? this.value,
    secondaryValue: clearSecondary
        ? null
        : secondaryValue ?? this.secondaryValue,
    unit: unit ?? this.unit,
    measuredAt: measuredAt ?? this.measuredAt,
    source: source ?? this.source,
    sourceLineId: clearSourceLine ? null : sourceLineId ?? this.sourceLineId,
    note: note ?? this.note,
  );

  VitalJson toJson() => {
    'id': id,
    'profileId': profileId,
    'kind': kind.name,
    'value': value,
    'secondaryValue': secondaryValue,
    'unit': unit,
    'measuredAt': measuredAt.toIso8601String(),
    'source': source,
    'sourceLineId': sourceLineId,
    'note': note,
  };

  factory VitalEntry.fromJson(VitalJson j) {
    final kind = VitalKind.values.byName(j['kind'] as String);
    return VitalEntry(
      id: j['id'] as String,
      profileId: j['profileId'] as String,
      kind: kind,
      value: (j['value'] as num).toDouble(),
      secondaryValue: (j['secondaryValue'] as num?)?.toDouble(),
      unit: j['unit'] as String? ?? defaultVitalUnit(kind),
      measuredAt: DateTime.parse(j['measuredAt'] as String),
      source: j['source'] as String? ?? 'user',
      sourceLineId: j['sourceLineId'] as String?,
      note: j['note'] as String? ?? '',
    );
  }
}

/// Validates ownership fields and broad recordable bounds, then appends.
///
/// Bounds are physical, not clinical cutoffs, so critical outliers stay
/// trackable: SpO2 0–100, pulse 0–400, blood pressure 0–400 each, temperature
/// −100–100 °C (converted when stored as °F), height 0–300 cm, weight
/// 0–1000 kg. Units must match exactly
/// (%, mmHg, bpm, °C/°F) — never a substring guess. Only blood pressure may
/// carry a second value. Throws [FormatException] on bad values and
/// [StateError] on missing or duplicate identity — never stores a guess.
List<VitalEntry> addVital(List<VitalEntry> entries, VitalEntry entry) {
  if (entry.id.isEmpty || entry.profileId.isEmpty) {
    throw StateError('Vital entry identity is required.');
  }
  if (entries.any((existing) => existing.id == entry.id)) {
    throw StateError('A vital entry with this ID already exists.');
  }
  if (!entry.value.isFinite) {
    throw const FormatException('Vital value must be a finite number.');
  }
  final secondary = entry.secondaryValue;
  if (secondary != null && !secondary.isFinite) {
    throw const FormatException('Vital value must be a finite number.');
  }
  // At most 3 decimals, with epsilon tolerance for binary float noise —
  // genuine fourth-decimal input is rejected with a clear message instead
  // of being silently rounded in storage.
  if (!_withinThreeDecimals(entry.value) ||
      (secondary != null && !_withinThreeDecimals(secondary))) {
    throw const FormatException(
      'Use at most 3 decimal places (for example 70.125 kg).',
    );
  }
  if (entry.measuredAt.isAfter(
    DateTime.now().add(const Duration(minutes: 5)),
  )) {
    throw const FormatException('Vital date cannot be in the future.');
  }
  // Provenance: manual entries are user-reported; report-linked entries must
  // name their evidence row. Anything else is rejected, never recorded.
  if (entry.source != 'user' && entry.source != 'report') {
    throw const FormatException('Vital source is user or report.');
  }
  if (entry.source == 'report' &&
      (entry.sourceLineId == null || entry.sourceLineId!.isEmpty)) {
    throw const FormatException('Report-linked vitals need a source row.');
  }
  final unit = entry.unit.trim().toLowerCase();
  switch (entry.kind) {
    case VitalKind.spo2:
      _requireUnit(unit, const {'%'}, 'SpO2 is recorded in %.');
      _requireRange(entry.value, 0, 100, 'SpO2 must be 0–100%.');
    case VitalKind.bloodPressure:
      _requireUnit(unit, const {'mmhg'}, 'Blood pressure is recorded in mmHg.');
      if (secondary == null) {
        throw const FormatException(
          'Blood pressure needs systolic and diastolic.',
        );
      }
      _requireRange(entry.value, 0, 400, 'Systolic must be 0–400 mmHg.');
      _requireRange(secondary, 0, 400, 'Diastolic must be 0–400 mmHg.');
    case VitalKind.temperature:
      if (unit != '°c' && unit != 'c' && unit != '°f' && unit != 'f') {
        throw const FormatException('Temperature is recorded in °C or °F.');
      }
      final celsius = unit == '°f' || unit == 'f'
          ? (entry.value - 32) * 5 / 9
          : entry.value;
      _requireRange(
        celsius,
        -100,
        100,
        'Temperature is outside recordable bounds.',
      );
    case VitalKind.pulse:
      _requireUnit(unit, const {'bpm'}, 'Pulse is recorded in bpm.');
      _requireRange(entry.value, 0, 400, 'Pulse must be 0–400 bpm.');
    case VitalKind.height:
      _requireUnit(unit, const {'cm'}, 'Height is recorded in cm.');
      _requireRange(entry.value, 0, 300, 'Height must be 0–300 cm.');
    case VitalKind.weight:
      _requireUnit(unit, const {'kg'}, 'Weight is recorded in kg.');
      _requireRange(entry.value, 0, 1000, 'Weight must be 0–1000 kg.');
  }
  if (entry.kind != VitalKind.bloodPressure && secondary != null) {
    throw const FormatException('Only blood pressure carries two values.');
  }
  return [...entries, entry];
}

void _requireUnit(String unit, Set<String> allowed, String message) {
  if (!allowed.contains(unit)) throw FormatException(message);
}

void _requireRange(double value, double min, double max, String message) {
  if (value < min || value > max) throw FormatException(message);
}

bool _withinThreeDecimals(double value) {
  final rounded = (value * 1000).roundToDouble() / 1000;
  return (value - rounded).abs() < 1e-9;
}

/// Display formatting shared by summaries and the metrics screen: integers
/// print whole, others print up to 3 decimals with trailing zeros removed.
/// Display-only — stored values are never rounded by this.
String formatVitalValue(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  var text = value.toStringAsFixed(3);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text;
}

/// Newest-first series for one profile, optionally filtered to a kind.
/// Pure read helper for trend views; callers cap the window they render.
List<VitalEntry> vitalsFor(
  List<VitalEntry> entries,
  String profileId, {
  VitalKind? kind,
}) {
  final rows =
      entries
          .where(
            (e) => e.profileId == profileId && (kind == null || e.kind == kind),
          )
          .toList()
        ..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
  return rows;
}

/// Latest entry for one profile/kind, or null when nothing is recorded.
VitalEntry? latestVital(
  List<VitalEntry> entries,
  String profileId,
  VitalKind kind,
) {
  final rows = vitalsFor(entries, profileId, kind: kind);
  return rows.isEmpty ? null : rows.first;
}
