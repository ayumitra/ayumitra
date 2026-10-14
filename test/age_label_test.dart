// Automatic current-age reference checks. Synthetic only, no models.
import 'package:ayumitra/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _profile({DateTime? dob, int? age, DateTime? recordedAt}) => Profile(
  id: 'p',
  name: 'Synthetic',
  history: '',
  dateOfBirth: dob,
  age: age,
  ageRecordedAt: recordedAt,
);

void main() {
  test('exact calendar age from DOB', () {
    final profile = _profile(dob: DateTime.utc(2020, 3, 15));
    expect(currentAgeLabel(profile, now: DateTime.utc(2026, 10, 14)), 'Age 6');
    // Birthday today counts the completed year.
    expect(
      currentAgeLabel(
        _profile(dob: DateTime.utc(2020, 10, 14)),
        now: DateTime.utc(2026, 10, 14),
      ),
      'Age 6',
    );
  });

  test(
    'age at a birth-day event compares calendar days rather than clock instants',
    () {
      final profile = _profile(dob: DateTime.utc(2024, 3, 14, 18));
      expect(ageAtEvent(profile, DateTime.utc(2024, 3, 14, 0)), 'Age 0 months');
      expect(
        ageAtEvent(profile, DateTime.utc(2024, 3, 13, 23)),
        'Age at event unknown',
      );
    },
  );

  test('pediatric precision under two years', () {
    expect(
      currentAgeLabel(
        _profile(dob: DateTime.utc(2026, 1, 10)),
        now: DateTime.utc(2026, 10, 14),
      ),
      'Age 9 months',
    );
    expect(
      currentAgeLabel(
        _profile(dob: DateTime.utc(2025, 3, 20)),
        now: DateTime.utc(2026, 10, 14),
      ),
      'Age 1 year, 6 months',
    );
    expect(
      currentAgeLabel(
        _profile(dob: DateTime.utc(2025, 9, 14)),
        now: DateTime.utc(2026, 10, 14),
      ),
      'Age 1 year, 1 month',
    );
    expect(
      currentAgeLabel(
        _profile(dob: DateTime.utc(2026, 9, 14)),
        now: DateTime.utc(2026, 10, 14),
      ),
      'Age 1 month',
    );
  });

  test('legacy integer age stays explicitly approximate', () {
    expect(
      currentAgeLabel(
        _profile(age: 8, recordedAt: DateTime.utc(2026, 1, 1)),
        now: DateTime.utc(2026, 10, 14),
      ),
      'About age 9',
    );
  });

  test('missing or impossible dates stay unknown, never invented', () {
    expect(
      currentAgeLabel(_profile(), now: DateTime.utc(2026, 10, 14)),
      'Age unknown',
    );
    expect(
      currentAgeLabel(
        _profile(dob: DateTime.utc(2027, 1, 1)),
        now: DateTime.utc(2026, 10, 14),
      ),
      'Age unknown',
    );
    expect(
      currentAgeLabel(_profile(age: 8), now: DateTime.utc(2026, 10, 14)),
      'Age unknown',
    );
  });
}
