import 'package:ayumitra/domain/profile_context.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _owner({DateTime? dob, int? age, DateTime? ageRecordedAt}) => Profile(
  id: 'owner',
  name: 'Synthetic Child',
  history: 'Not included',
  dateOfBirth: dob,
  age: age,
  ageRecordedAt: ageRecordedAt,
);
VitalEntry _reading(
  String id,
  VitalKind kind,
  double value,
  DateTime at, {
  String profileId = 'owner',
  String source = 'user',
  String? unit,
}) => VitalEntry(
  id: id,
  profileId: profileId,
  kind: kind,
  value: value,
  unit: unit ?? defaultVitalUnit(kind),
  measuredAt: at,
  source: source,
  sourceLineId: source == 'report' ? 'owned-row' : null,
);

void main() {
  test('DOB and pediatric calendar age are exact and dated', () {
    final now = DateTime.utc(2026, 10, 14, 9, 30);
    final context = buildProfileContext(
      _owner(dob: DateTime.utc(2025, 3, 20, 13)),
      [],
      now: now,
    );
    expect(context['dateOfBirth'], '2025-03-20');
    expect(context['ageLabel'], 'Age 1 year, 6 months');
    expect(context['exactAge'], {'years': 1, 'months': 6, 'days': 24});
    expect(context['currentDateTime'], now.toIso8601String());
    expect(context['timeZoneOffsetMinutes'], 0);
    expect(context.containsKey('profileId'), false);
    expect(context.containsKey('name'), false);
    expect(context.containsKey('history'), false);
  });
  test('birthday, preceding day and infant age never use rounded years', () {
    final owner = _owner(dob: DateTime.utc(2020, 10, 14));
    expect(
      buildProfileContext(
        owner,
        [],
        now: DateTime.utc(2026, 10, 14),
      )['exactAge'],
      {'years': 6, 'months': 0, 'days': 0},
    );
    expect(
      buildProfileContext(
        owner,
        [],
        now: DateTime.utc(2026, 10, 13),
      )['exactAge'],
      {'years': 5, 'months': 11, 'days': 29},
    );
    expect(
      buildProfileContext(
        _owner(dob: DateTime.utc(2026, 10, 13)),
        [],
        now: DateTime.utc(2026, 10, 14),
      )['exactAge'],
      {'years': 0, 'months': 0, 'days': 1},
    );
  });
  test('leap birthdays follow the existing age-label March 1 policy', () {
    final owner = _owner(dob: DateTime.utc(2024, 2, 29));
    expect(
      buildProfileContext(
        owner,
        [],
        now: DateTime.utc(2025, 2, 28),
      )['exactAge'],
      {'years': 0, 'months': 11, 'days': 30},
    );
    expect(
      buildProfileContext(owner, [], now: DateTime.utc(2025, 3, 1))['exactAge'],
      {'years': 1, 'months': 0, 'days': 0},
    );
    expect(
      buildProfileContext(
        owner,
        [],
        now: DateTime.utc(2028, 2, 29),
      )['exactAge'],
      {'years': 4, 'months': 0, 'days': 0},
    );
  });
  test('short-month boundaries produce nonnegative calendar days', () {
    expect(
      buildProfileContext(
        _owner(dob: DateTime.utc(2025, 1, 31)),
        [],
        now: DateTime.utc(2025, 3, 1),
      )['exactAge'],
      {'years': 0, 'months': 1, 'days': 1},
    );
    expect(
      buildProfileContext(
        _owner(dob: DateTime.utc(2024, 1, 31)),
        [],
        now: DateTime.utc(2024, 3, 1),
      )['exactAge'],
      {'years': 0, 'months': 1, 'days': 1},
    );
  });
  test('legacy or absent DOB remains unknown rather than being invented', () {
    final now = DateTime.utc(2026, 10, 14);
    final legacy = buildProfileContext(
      _owner(age: 8, ageRecordedAt: DateTime.utc(2026, 1, 1)),
      [],
      now: now,
    );
    expect(legacy['dateOfBirth'], isNull);
    expect(legacy['exactAge'], isNull);
    expect(legacy['ageLabel'], startsWith('About age '));
    final unknown = buildProfileContext(_owner(), [], now: now);
    expect(unknown['ageLabel'], 'Age unknown');
    expect(unknown['currentHeight'], isNull);
    expect(unknown['currentWeight'], isNull);
    final future = buildProfileContext(
      _owner(dob: DateTime.utc(2027)),
      [],
      now: now,
    );
    expect(future['dateOfBirth'], isNull);
    expect(future['exactAge'], isNull);
  });
  test(
    'latest owned height and weight retain precision, unit, date and provenance',
    () {
      final now = DateTime.utc(2026, 10, 14, 12);
      final heightDate = DateTime.utc(2026, 10, 12, 8, 45);
      final weightDate = DateTime.utc(2026, 10, 13, 9, 30);
      final readings = [
        _reading(
          'old-weight',
          VitalKind.weight,
          11.111,
          DateTime.utc(2026, 10, 1),
        ),
        _reading(
          'height',
          VitalKind.height,
          123.456,
          heightDate,
          source: 'report',
        ),
        _reading('weight', VitalKind.weight, 12.345, weightDate),
        _reading('other-weight', VitalKind.weight, 99, now, profileId: 'other'),
        _reading('pulse', VitalKind.pulse, 70, now),
      ];
      final context = buildProfileContext(
        _owner(dob: DateTime.utc(2020)),
        readings,
        now: now,
      );
      expect(context['currentWeight'], {
        'value': 12.345,
        'unit': 'kg',
        'measuredAt': weightDate.toIso8601String(),
        'source': 'user',
        'sourceId': 'vitals',
      });
      expect(context['currentHeight'], {
        'value': 123.456,
        'unit': 'cm',
        'measuredAt': heightDate.toIso8601String(),
        'source': 'report',
        'sourceId': 'vitals',
      });
      expect(readings.first.id, 'old-weight'); // Input order is never mutated.
    },
  );
  test('future and pre-DOB readings cannot supply current measurements', () {
    final now = DateTime.utc(2026, 10, 14, 12);
    final birth = DateTime.utc(2026, 10, 10, 15);
    final context = buildProfileContext(_owner(dob: birth), [
      _reading(
        'before-birth',
        VitalKind.weight,
        3,
        DateTime.utc(2026, 10, 9, 23),
      ),
      _reading(
        'birth-day',
        VitalKind.weight,
        3.125,
        DateTime.utc(2026, 10, 10, 8),
      ),
      _reading(
        'future',
        VitalKind.weight,
        4.5,
        now.add(const Duration(seconds: 1)),
      ),
      _reading(
        'future-height',
        VitalKind.height,
        55,
        DateTime.utc(2026, 10, 15),
      ),
      _reading(
        'pre-birth-height',
        VitalKind.height,
        50,
        DateTime.utc(2026, 10, 9),
      ),
    ], now: now);
    expect((context['currentWeight'] as Map)['value'], 3.125);
    expect(context['currentHeight'], isNull);
  });
  test(
    'nonfinite measurements or mismatched units are not current context',
    () {
      final now = DateTime.utc(2026, 10, 14);
      final context = buildProfileContext(_owner(), [
        _reading('nan', VitalKind.weight, double.nan, now),
        _reading('wrong-unit', VitalKind.height, 1.2, now, unit: 'kg'),
      ], now: now);
      expect(context['currentWeight'], isNull);
      expect(context['currentHeight'], isNull);
    },
  );
  test(
    'invalid persisted bounds, extra precision and secondary values never enter current context',
    () {
      final now = DateTime.utc(2026, 10, 14);
      final earlier = now.subtract(const Duration(days: 1));
      final context = buildProfileContext(_owner(), [
        _reading('good-weight', VitalKind.weight, 70.125, earlier),
        _reading('negative', VitalKind.weight, -0.001, now),
        _reading('too-heavy', VitalKind.weight, 1000.001, now),
        _reading('precision', VitalKind.weight, 70.1254, now),
        _reading(
          'secondary',
          VitalKind.weight,
          70,
          now,
        ).copy(secondaryValue: 80),
        _reading('too-tall', VitalKind.height, 300.001, now),
        _reading('negative-height', VitalKind.height, -1, now),
        _reading('infinite-height', VitalKind.height, double.infinity, now),
      ], now: now);
      expect((context['currentWeight'] as Map)['value'], 70.125);
      expect(context['currentHeight'], isNull);
      // Physical-boundary values remain recordable; these are not normal ranges.
      final boundaries = buildProfileContext(_owner(), [
        _reading('weight-max', VitalKind.weight, 1000, now),
        _reading('height-max', VitalKind.height, 300, now),
      ], now: now);
      expect((boundaries['currentWeight'] as Map)['value'], 1000);
      expect((boundaries['currentHeight'] as Map)['value'], 300);
    },
  );

  test('report readings require a nonempty source row and valid identity', () {
    final now = DateTime.utc(2026, 10, 14);
    final good = _reading(
      'good-report',
      VitalKind.weight,
      70.125,
      now.subtract(const Duration(days: 1)),
      source: 'report',
    );
    final context = buildProfileContext(_owner(), [
      good,
      _reading(
        'missing-row',
        VitalKind.weight,
        71,
        now,
        source: 'report',
      ).copy(clearSourceLine: true),
      _reading(
        'blank-row',
        VitalKind.weight,
        72,
        now,
        source: 'report',
      ).copy(sourceLineId: '   '),
      _reading(
        'unknown-source',
        VitalKind.weight,
        73,
        now,
        source: 'assistant',
      ),
      _reading('   ', VitalKind.weight, 74, now),
    ], now: now);
    expect((context['currentWeight'] as Map)['value'], 70.125);
    expect((context['currentWeight'] as Map)['source'], 'report');
    expect((context['currentWeight'] as Map)['sourceId'], 'vitals');
  });
}
