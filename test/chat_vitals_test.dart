import 'package:ayumitra/domain/chat_vitals.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final provided = DateTime(2024, 10, 14, 10, 30);
  List<VitalEntry> extract(
    String text, {
    String owner = 'alice',
    String turn = 'u1',
  }) => extractChatVitals(
    text: text,
    profileId: owner,
    turnId: turn,
    providedAt: provided,
  );

  test('explicit readings retain values, units and user turn provenance', () {
    final rows = extract(
      'My blood pressure was 120/80 mmHg, SpO2 was 98%, '
      'pulse was 72 bpm, and temperature was 37.2 °C.',
    );
    expect(rows, hasLength(4));
    final byKind = {for (final row in rows) row.kind: row};
    expect(byKind[VitalKind.bloodPressure]!.value, 120);
    expect(byKind[VitalKind.bloodPressure]!.secondaryValue, 80);
    expect(byKind[VitalKind.bloodPressure]!.unit, 'mmHg');
    expect(byKind[VitalKind.spo2]!.value, 98);
    expect(byKind[VitalKind.spo2]!.unit, '%');
    expect(byKind[VitalKind.pulse]!.value, 72);
    expect(byKind[VitalKind.pulse]!.unit, 'bpm');
    expect(byKind[VitalKind.temperature]!.value, 37.2);
    expect(byKind[VitalKind.temperature]!.unit, '°C');
    for (final row in rows) {
      expect(row.profileId, 'alice');
      expect(row.id, 'chat:u1:${row.kind.name}');
      expect(row.source, 'user');
      expect(row.sourceLineId, isNull);
      expect(row.note, contains('u1'));
      expect(row.measuredAt, provided);
    }
  });

  test('BP label permits standard unit while bare ratio requires mmHg', () {
    for (final text in ['BP 120/80', 'Blood pressure: 120/80', '120/80 mmHg']) {
      expect(extract(text).single.kind, VitalKind.bloodPressure, reason: text);
    }
    for (final text in ['120/80', 'BP 120/80 kPa', 'BP 120/80 bpm']) {
      expect(extract(text), isEmpty, reason: text);
    }
  });

  test('sentence punctuation after a BP value does not invalidate it', () {
    expect(extract('My blood pressure was 120/80.').single.secondaryValue, 80);
    expect(extract('BP 120/80.5.').single.secondaryValue, 80.5);
    expect(extract('BP 120/80.5.3'), isEmpty);
  });

  test('oxygen and pulse require explicit labels and clear units', () {
    for (final text in [
      'SpO2 98%.',
      'SpO₂: 98%',
      'Oxygen saturation was 98 percent',
      'O2 saturation is 98%',
    ]) {
      expect(extract(text).single.kind, VitalKind.spo2, reason: text);
    }
    for (final text in [
      'Pulse 72 bpm.',
      'Heart rate was 72 bpm',
      'Heartrate: 72 bpm',
    ]) {
      expect(extract(text).single.kind, VitalKind.pulse, reason: text);
    }
    for (final text in [
      '98%',
      '72 bpm',
      'Pulse 72',
      'SpO2 98',
      'Oxygen 98%',
      'Pulse 72 kg',
    ]) {
      expect(extract(text), isEmpty, reason: text);
    }
  });

  test('temperature never guesses a scale or converts a recorded value', () {
    for (final text in [
      'Temperature 98.6 °F',
      'Temp was 98.6 Fahrenheit',
      'Temperature: 98.6 degrees F',
    ]) {
      final row = extract(text).single;
      expect(row.value, 98.6);
      expect(row.unit, '°F');
    }
    expect(extract('Temperature 37 Celsius').single.unit, '°C');
    for (final text in [
      'Temperature 37',
      'Temperature 98.6',
      '37 °C',
      'Temperature 37 °CF',
    ]) {
      expect(extract(text), isEmpty, reason: text);
    }
  });

  test('memory wrappers still record an explicit real reading', () {
    for (final text in [
      'Remember my pulse was 72 bpm',
      'Please record that my blood pressure was 120/80',
      'Save that my SpO2 was 98%',
      'Log temperature 37 °C',
    ]) {
      expect(extract(text), hasLength(1), reason: text);
    }
  });

  test(
    'questions, uncertainty, negation, examples and hypothetical drafts are ignored',
    () {
      for (final text in [
        'Was my pulse 72 bpm?',
        'Is a blood pressure of 120/80 normal?',
        'What if my BP was 120/80?',
        'My pulse was not 72 bpm',
        "I didn't record a blood pressure of 120/80 mmHg",
        "I don't have BP 120/80 mmHg",
        'My SpO2 might be 98%',
        'My BP was approximately 120/80 mmHg',
        'For example, blood pressure 120/80 mmHg',
        'Create a health report with BP 120/80 mmHg',
        'Draft a note. BP 120/80 mmHg',
        'Imagine my temperature was 37 °C',
        'Remember an example pulse of 72 bpm',
        'My pulse would be 72 bpm',
        'My pulse should be 72 bpm',
        'Normal blood pressure is 120/80 mmHg',
        'Someone has pulse 72 bpm',
        'The report says BP 120/80 mmHg',
      ]) {
        expect(extract(text), isEmpty, reason: text);
      }
    },
  );

  test('quoted source text is never taken as a reported reading', () {
    for (final text in [
      'The example says "BP 120/80 mmHg"',
      'Someone wrote “Pulse 72 bpm”',
      "Someone wrote 'Temperature 37 °C'",
      '`SpO2 98%`',
      '```text\nBP 120/80 mmHg\n```',
      '> Pulse 72 bpm',
    ]) {
      expect(extract(text), isEmpty, reason: text);
    }
    expect(
      extract('My pulse was 72 bpm. The example says "SpO2 98%"'),
      hasLength(1),
    );
  });

  test(
    'a declaration followed by a question keeps only the declared reading',
    () {
      for (final text in [
        'My blood pressure was 120/80, is that normal?',
        'My blood pressure was 120/80 and what does it mean?',
        'My blood pressure was 120/80. Should pulse be 90 bpm?',
        'My blood pressure was 120/80; could temperature be 37 °C?',
        'My blood pressure was 120/80; what if pulse was 90 bpm?',
      ]) {
        final rows = extract(text);
        expect(rows, hasLength(1), reason: text);
        expect(rows.single.kind, VitalKind.bloodPressure);
      }
    },
  );

  test('explicit event date takes precedence over the provided date', () {
    for (final date in [
      '2024-03-14',
      'March 14, 2024',
      '14 March 2024',
      '14/03/2024',
      '03/14/2024',
    ]) {
      expect(
        extract('My pulse was 72 bpm on $date').single.measuredAt,
        DateTime(2024, 3, 14),
        reason: date,
      );
    }
    expect(
      extract('Yesterday my pulse was 72 bpm').single.measuredAt,
      DateTime(2024, 10, 13),
    );
    expect(
      extract('My pulse was 72 bpm today').single.measuredAt,
      DateTime(2024, 10, 14),
    );
  });

  test('one explicit date can date other clear readings in the same turn', () {
    final rows = extract('My pulse was 72 bpm. My SpO2 was 98% on 2024-03-14');
    expect(rows, hasLength(2));
    expect(
      rows.every((row) => row.measuredAt == DateTime(2024, 3, 14)),
      isTrue,
    );
  });

  test(
    'ambiguous, future, incomplete and contradictory dates are not replaced by today',
    () {
      for (final text in [
        'BP 120/80 on 03/04/2024',
        'BP 120/80 on February 30, 2024',
        'BP 120/80 on 2024-10-15',
        'BP 120/80 tomorrow',
        'BP 120/80 last month',
        'BP 120/80 on March 14',
        'BP 120/80 on 14/03/24',
        'BP 120/80 today on 2024-03-14',
        'BP 120/80 on 2024-03-14 and 2024-03-15',
      ]) {
        expect(extract(text), isEmpty, reason: text);
      }
    },
  );

  test('individually dated different kinds retain their own event dates', () {
    final rows = extract(
      'My pulse was 72 bpm on 2024-03-14. My SpO2 was 98% on 2024-03-15. Temperature 37 °C.',
    );
    expect(rows, hasLength(2));
    expect(rows.first.measuredAt, DateTime(2024, 3, 14));
    expect(rows.last.measuredAt, DateTime(2024, 3, 15));
  });

  test(
    'conflicting same-kind readings are omitted rather than arbitrarily chosen',
    () {
      expect(extract('Pulse 72 bpm and pulse 80 bpm'), isEmpty);
      expect(extract('Temperature 37 °C. Temperature 98.6 °F.'), isEmpty);
      expect(extract('Pulse 72 bpm. Pulse 72 bpm.'), hasLength(1));
    },
  );

  test(
    'broad physical bounds reject malformed values without rejecting critical readings',
    () {
      for (final text in [
        'SpO2 101%',
        'Pulse 401 bpm',
        'BP 500/80',
        'Temperature 120 °C',
        'Pulse NaN bpm',
        'Temperature Infinity °C',
      ]) {
        expect(extract(text), isEmpty, reason: text);
      }
      expect(extract('SpO2 60%').single.value, 60);
      expect(extract('Pulse 200 bpm').single.value, 200);
      expect(extract('BP 220/130').single.value, 220);
    },
  );

  test(
    'identities are stable for replay and scoped only to the caller owner',
    () {
      final first = extract('Pulse 72 bpm').single;
      final replay = extract('Pulse 72 bpm').single;
      expect(first.toJson(), replay.toJson());
      expect(extract('Pulse 72 bpm', owner: 'bob').single.profileId, 'bob');
      expect(extract('Pulse 72 bpm', turn: 'u2').single.id, isNot(first.id));
      expect(extract('Pulse 72 bpm', owner: ''), isEmpty);
      expect(extract('Pulse 72 bpm', turn: ''), isEmpty);
    },
  );

  test('height records centimeters with decimals, never bare numbers', () {
    for (final text in [
      'My height is 179 cm.',
      'Height: 179.5 cm',
      'My height: I am 179 cm tall',
    ]) {
      final row = extract(text).single;
      expect(row.kind, VitalKind.height, reason: text);
      expect(row.unit, 'cm');
    }
    expect(extract('My height is 179 cm.').single.value, 179);
    expect(extract('Height: 179.5 cm').single.value, 179.5);
    for (final text in ['My height is 179.', 'Height 400 cm', 'Tall']) {
      expect(extract(text), isEmpty, reason: text);
    }
  });

  test('explicit unit conversions retain three canonical decimal places', () {
    expect(extract('My weight is 154 lbs.').single.value, 69.853);
    expect(extract('My height is 5 ft 9 in.').single.value, 175.26);
    expect(extract('My height is 1.79123 m.').single.value, 179.123);
    expect(extract('My weight is 70.1234 kg.'), isEmpty);
  });

  test('explicit measurement clock times are retained, never message time', () {
    expect(
      extract('My pulse was 72 bpm on 2024-03-14 at 08:15').single.measuredAt,
      DateTime(2024, 3, 14, 8, 15),
    );
    expect(
      extract('My pulse was 72 bpm yesterday at 8:15 pm').single.measuredAt,
      DateTime(2024, 10, 13, 20, 15),
    );
    expect(extract('My pulse was 72 bpm at 25:15'), isEmpty);
  });

  test('height converts meters and feet/inches to centimeters', () {
    final meters = extract('My height is 1.79 m.').single;
    expect(meters.kind, VitalKind.height);
    expect(meters.value, 179);
    expect(meters.unit, 'cm');
    final imperial = extract('My height is 5\'9".').single;
    expect(imperial.kind, VitalKind.height);
    expect(imperial.value, closeTo(175.3, 0.05));
    final words = extract('Height 5 ft 9 in.').single;
    expect(words.value, closeTo(175.3, 0.05));
    // Implausible or ambiguous forms are skipped, never guessed.
    expect(extract('My height is 179 m.'), isEmpty);
    expect(extract("It's 5'."), isEmpty);
  });

  test('weight records kilograms with decimals, converting pounds', () {
    final kg = extract('My weight is 70.5 kg.').single;
    expect(kg.kind, VitalKind.weight);
    expect(kg.value, 70.5);
    expect(kg.unit, 'kg');
    expect(extract('Weighs 70 kg').single.value, 70);
    final lb = extract('My weight is 154 lbs.').single;
    expect(lb.kind, VitalKind.weight);
    expect(lb.value, closeTo(69.9, 0.05));
    expect(lb.unit, 'kg');
    for (final text in ['My weight is 70.', 'Weight 2000 kg']) {
      expect(extract(text), isEmpty, reason: text);
    }
  });

  test('first-person copular forms record unambiguous units', () {
    for (final text in ['I weigh 70 kg', "I'm 70kg", 'im 70 kilos']) {
      final row = extract(text).single;
      expect(row.kind, VitalKind.weight, reason: text);
      expect(row.value, 70);
      expect(row.unit, 'kg');
    }
    for (final text in [
      'I am 179 cm',
      "I'm 179cm tall",
      'im 179 centimeters',
    ]) {
      final row = extract(text).single;
      expect(row.kind, VitalKind.height, reason: text);
      expect(row.value, 179);
      expect(row.unit, 'cm');
    }
    expect(extract('My temperature is 37 C').single.value, 37);
    expect(extract("I'm 72 bpm").single.kind, VitalKind.pulse);
    // Bare % stays unrecorded: confidence is not a reading.
    expect(extract("I'm 100% sure"), isEmpty);
    expect(extract('I am 98'), isEmpty);
  });
}
