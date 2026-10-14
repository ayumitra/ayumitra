// Synthetic vitals checks. No models, no network.
import 'dart:convert';

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/profile_deletion.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/services/vitals_summary.dart';
import 'package:flutter_test/flutter_test.dart';

VitalEntry _entry({
  String id = 'v1',
  String profileId = 'p',
  VitalKind kind = VitalKind.spo2,
  double value = 98,
  double? secondary,
  String? unit,
  DateTime? at,
}) => VitalEntry(
  id: id,
  profileId: profileId,
  kind: kind,
  value: value,
  secondaryValue: secondary,
  unit: unit ?? defaultVitalUnit(kind),
  measuredAt: at ?? DateTime.utc(2026, 10, 1),
);

final _measured = DateTime.utc(2026, 10, 2);

void main() {
  test('accepts one reading per supported kind', () {
    var entries = <VitalEntry>[];
    entries = addVital(entries, _entry(kind: VitalKind.spo2, value: 98));
    entries = addVital(
      entries,
      _entry(
        id: 'v2',
        kind: VitalKind.bloodPressure,
        value: 120,
        secondary: 80,
      ),
    );
    entries = addVital(
      entries,
      _entry(id: 'v3', kind: VitalKind.temperature, value: 37.2),
    );
    entries = addVital(
      entries,
      _entry(id: 'v4', kind: VitalKind.pulse, value: 72),
    );
    entries = addVital(
      entries,
      _entry(id: 'v5', kind: VitalKind.height, value: 179.5),
    );
    entries = addVital(
      entries,
      _entry(id: 'v6', kind: VitalKind.weight, value: 70.2),
    );
    expect(entries, hasLength(6));
  });

  test('rejects out-of-range values and missing identity', () {
    expect(() => addVital([], _entry(value: 140)), throwsFormatException);
    expect(
      () => addVital([], _entry(kind: VitalKind.pulse, value: 450)),
      throwsFormatException,
    );
    expect(
      () => addVital([], _entry(kind: VitalKind.bloodPressure, value: 120)),
      throwsFormatException,
    );
    expect(() => addVital([], _entry(id: '')), throwsStateError);
    expect(
      () =>
          addVital([], _entry(at: DateTime.now().add(const Duration(days: 1)))),
      throwsFormatException,
    );
  });

  test('rejects non-finite values', () {
    expect(
      () => addVital([], _entry(value: double.nan)),
      throwsFormatException,
    );
    expect(
      () => addVital([], _entry(value: double.infinity)),
      throwsFormatException,
    );
    expect(
      () => addVital(
        [],
        _entry(
          kind: VitalKind.bloodPressure,
          value: 120,
          secondary: double.nan,
        ),
      ),
      throwsFormatException,
    );
  });

  test('units must match exactly, never by substring', () {
    for (final bad in ['percent', '%%', 'mm Hg', 'bpm2', 'degrees']) {
      expect(() => addVital([], _entry(unit: bad)), throwsFormatException);
    }
    // Exact match is case-insensitive; surrounding whitespace is trimmed.
    expect(addVital([], _entry(unit: ' % ')), hasLength(1));
    expect(
      () => addVital(
        [],
        _entry(kind: VitalKind.temperature, value: 37, unit: 'kelvin'),
      ),
      throwsFormatException,
    );
  });

  test('only blood pressure carries a second value', () {
    expect(() => addVital([], _entry(secondary: 70)), throwsFormatException);
    expect(
      () =>
          addVital([], _entry(kind: VitalKind.pulse, value: 72, secondary: 70)),
      throwsFormatException,
    );
  });

  test('duplicate entry IDs are rejected', () {
    final entries = addVital([], _entry(id: 'v1'));
    expect(() => addVital(entries, _entry(id: 'v1')), throwsStateError);
    expect(addVital(entries, _entry(id: 'v2')), hasLength(2));
  });

  test('sources are user-reported or report-linked with a row', () {
    expect(
      () => addVital([], _entry().copy(source: 'clinic')),
      throwsFormatException,
    );
    expect(
      () => addVital([], _entry().copy(source: 'report')),
      throwsFormatException,
    );
    expect(
      addVital([], _entry().copy(source: 'report', sourceLineId: 'r1/p1-l2')),
      hasLength(1),
    );
  });

  test('bounds stay physical so critical outliers remain trackable', () {
    // Extreme but physically recordable readings are kept, not refused.
    expect(addVital([], _entry(value: 0)), hasLength(1));
    expect(
      addVital([], _entry(kind: VitalKind.pulse, value: 350, id: 'critical')),
      hasLength(1),
    );
    expect(
      addVital(
        [],
        _entry(
          kind: VitalKind.bloodPressure,
          value: 350,
          secondary: 250,
          id: 'crisis',
        ),
      ),
      hasLength(1),
    );
    // Fahrenheit converts before the physical check.
    expect(
      addVital(
        [],
        _entry(kind: VitalKind.temperature, value: 98.6, unit: '°F', id: 'f'),
      ),
      hasLength(1),
    );
    expect(
      () => addVital(
        [],
        _entry(kind: VitalKind.temperature, value: 300, unit: '°F'),
      ),
      throwsFormatException,
    );
    expect(
      () => addVital(
        [],
        _entry(kind: VitalKind.temperature, value: -150, unit: '°C'),
      ),
      throwsFormatException,
    );
  });

  test('height and weight validate units and physical bounds', () {
    expect(
      () => addVital([], _entry(kind: VitalKind.height, value: 400)),
      throwsFormatException,
    );
    expect(
      () => addVital([], _entry(kind: VitalKind.height, unit: 'meters')),
      throwsFormatException,
    );
    expect(
      () => addVital(
        [],
        _entry(kind: VitalKind.height, value: 179, secondary: 80),
      ),
      throwsFormatException,
    );
    expect(
      () => addVital([], _entry(kind: VitalKind.weight, value: -5)),
      throwsFormatException,
    );
    expect(
      () => addVital([], _entry(kind: VitalKind.weight, unit: 'lbs')),
      throwsFormatException,
    );
    expect(
      () => addVital([], _entry(kind: VitalKind.weight, value: 1200)),
      throwsFormatException,
    );
    expect(
      addVital([], _entry(kind: VitalKind.height, value: 0.5)),
      hasLength(1),
    );
  });

  test('series are newest-first and filterable by kind', () {
    final entries = [
      _entry(id: 'old', at: DateTime.utc(2026, 9, 1), value: 97),
      _entry(id: 'new', at: DateTime.utc(2026, 10, 1), value: 99),
      _entry(
        id: 'bp',
        kind: VitalKind.bloodPressure,
        value: 120,
        secondary: 80,
      ),
    ];
    final all = vitalsFor(entries, 'p');
    expect(all.map((e) => e.id), ['new', 'bp', 'old']);
    expect(vitalsFor(entries, 'p', kind: VitalKind.spo2).map((e) => e.id), [
      'new',
      'old',
    ]);
    expect(latestVital(entries, 'p', VitalKind.spo2)!.id, 'new');
    expect(latestVital(entries, 'p', VitalKind.pulse), isNull);
    expect(vitalsFor(entries, 'other'), isEmpty);
  });

  test('profile deletion purges that profile vitals only', () {
    const data = VaultData(
      profiles: [
        Profile(id: 'p', name: 'A', history: ''),
        Profile(id: 'q', name: 'B', history: ''),
      ],
    );
    final withVitals = data.copy(
      vitals: [
        _entry(profileId: 'p'),
        _entry(id: 'vq', profileId: 'q'),
      ],
    );
    final next = withoutProfile(withVitals, 'p', queueFileDeletion: false);
    expect(next.vitals.map((e) => e.profileId), ['q']);
  });

  test('vitals survive a vault JSON round trip', () {
    final withVitals = const VaultData().copy(
      vitals: [
        VitalEntry(
          id: 'v1',
          profileId: 'p',
          kind: VitalKind.bloodPressure,
          value: 118,
          secondaryValue: 76,
          unit: 'mmHg',
          measuredAt: _measured,
        ),
      ],
    );
    final decoded = VaultData.decode(jsonEncode(withVitals.toJson()));
    expect(decoded.vitals, hasLength(1));
    expect(decoded.vitals.single.value, 118);
    expect(decoded.vitals.single.secondaryValue, 76);
    expect(decoded.vitals.single.kind, VitalKind.bloodPressure);
  });

  test('summary lists latest readings newest-first, bounded per kind', () {
    expect(vitalsSummaryFor([], 'p'), isEmpty);
    expect(vitalsSummaryFor([_entry()], 'other'), isEmpty);
    final entries = [
      _entry(id: 's1', value: 97, at: DateTime.utc(2026, 9, 1)),
      _entry(id: 's2', value: 99, at: DateTime.utc(2026, 10, 1)),
      _entry(
        id: 'bp1',
        kind: VitalKind.bloodPressure,
        value: 120,
        secondary: 80,
        at: DateTime.utc(2026, 10, 2),
      ),
      _entry(
        id: 't1',
        kind: VitalKind.temperature,
        value: 37.2,
        at: DateTime.utc(2026, 10, 3),
      ),
    ];
    final summary = vitalsSummaryFor(entries, 'p');
    expect(summary, contains('user-reported, unverified'));
    expect(summary, contains('Oxygen saturation: latest 99% on 2026-10-01'));
    expect(summary, contains('(2 readings, 2026-09-01..2026-10-01)'));
    expect(summary, contains('97% on 2026-09-01'));
    expect(summary, contains('Blood pressure: latest 120/80 mmHg'));
    expect(summary, contains('Temperature: latest 37.2 °C'));
    // Bounded history per kind, never fabricated.
    final many = [
      for (var i = 0; i < 8; i++)
        _entry(
          id: 'm$i',
          value: 93 + i.toDouble(),
          at: DateTime.utc(2026, 9, 1 + i),
        ),
    ];
    final bounded = vitalsSummaryFor(many, 'p', maxPerKind: 3);
    expect(bounded, contains('latest 100%'));
    expect(bounded, contains('…'));
    expect(bounded, isNot(contains('93%')));
  });

  test('values accept up to 3 decimals, never more', () {
    expect(
      addVital([], _entry(kind: VitalKind.weight, value: 70.125)),
      hasLength(1),
    );
    expect(
      addVital([], _entry(kind: VitalKind.height, value: 179.5)),
      hasLength(1),
    );
    for (final value in [70.1234, 0.0001, 179.9999]) {
      try {
        addVital([], _entry(kind: VitalKind.weight, value: value));
        fail('expected a precision rejection for $value');
      } on FormatException catch (e) {
        expect(e.message, contains('3 decimal places'));
      }
    }
    expect(
      () => addVital(
        [],
        _entry(
          kind: VitalKind.bloodPressure,
          value: 120,
          secondary: 80.0001,
          id: 'precision',
        ),
      ),
      throwsFormatException,
    );
  });

  test('formatVitalValue prints up to 3 decimals without rounding storage', () {
    expect(formatVitalValue(98), '98');
    expect(formatVitalValue(37.2), '37.2');
    expect(formatVitalValue(70.125), '70.125');
    expect(formatVitalValue(70.1), '70.1');
    expect(formatVitalValue(120), '120');
  });
}
