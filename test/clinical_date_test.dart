import 'dart:convert';

import 'package:ayumitra/domain/clinical_date.dart';
import 'package:ayumitra/domain/extraction.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 12, 12);
  DateTime? validate(String proposed, String evidence, {String? sourceText}) =>
      validateClinicalDate(
        proposed: proposed,
        evidence: evidence,
        source: SourceLine(
          id: 'synthetic-l1',
          page: 1,
          text: sourceText ?? evidence,
        ),
        now: now,
      );

  group('clinical date grounding and normalization', () {
    test('normalizes common English and unambiguous numeric formats', () {
      for (final printed in [
        '2026-03-14',
        '2026/03/14',
        '14/03/2026',
        '03/14/2026',
        '14.03.2026',
        '14 March 2026',
        '14-Mar-2026',
        'March 14, 2026',
        '14th march 2026',
        'Mar. 14th, 2026',
      ]) {
        expect(
          validate('2026-03-14', 'Report date: $printed'),
          DateTime.utc(2026, 3, 14),
          reason: printed,
        );
      }
      expect(
        validate('2026-09-14', 'Collection date: 14 Sept 2026'),
        DateTime.utc(2026, 9, 14),
      );
      expect(
        validate('2026-03-03', 'Test date: 03/03/2026'),
        DateTime.utc(2026, 3, 3),
      );
    });

    test('refuses ambiguous numeric dates in either interpretation', () {
      expect(validate('2026-03-04', 'Report date: 04/03/2026'), isNull);
      expect(validate('2026-04-03', 'Report date: 04/03/2026'), isNull);
    });

    test('requires an exact quote and matching canonical proposal', () {
      expect(
        validate('2026-03-14', '14 March 2026', sourceText: '14 Mar 2026'),
        isNull,
      );
      expect(validate('2026-03-15', '14 March 2026'), isNull);
      expect(validate('14 March 2026', '14 March 2026'), isNull);
      expect(validate('2026-03-14', ''), isNull);
      expect(validate('2026-03-14', 'No clinical date printed'), isNull);
      expect(
        validate(
          '2026-03-14',
          'Report 14 March 2026; collection 13 March 2026',
        ),
        isNull,
      );
    });

    test('checks real calendar dates instead of accepting overflow', () {
      for (final date in [
        '2026-02-29',
        '2026-02-30',
        '2026-04-31',
        '2026-13-01',
        '2026-00-14',
        '2026-03-00',
        '0000-03-14',
      ]) {
        expect(validate(date, 'Report date: $date'), isNull, reason: date);
      }
      expect(
        validate('2024-02-29', 'Test date: 29 February 2024'),
        DateTime.utc(2024, 2, 29),
      );
      expect(validate('2026-02-28', 'Test date: 29 February 2026'), isNull);
    });

    test('rejects future dates but accepts the current calendar day', () {
      expect(validate('2026-10-13', 'Report date: 13 October 2026'), isNull);
      expect(
        validate('2026-10-12', 'Report date: 12 October 2026'),
        DateTime.utc(2026, 10, 12),
      );
    });

    test('cannot hide a birth label by quoting only its date', () {
      for (final label in [
        'DOB',
        'D.O.B.',
        'Date of birth',
        'Birth date',
        'Born',
      ]) {
        expect(
          validate(
            '2024-06-14',
            '2024-06-14',
            sourceText: '$label: 2024-06-14',
          ),
          isNull,
          reason: label,
        );
      }
      expect(validate('2024-06-14', '2024-06-14 (DOB)'), isNull);
      expect(
        validate(
          '2024-06-14',
          '2024-06-14',
          sourceText: 'Date of birth shown on this report: 2024-06-14',
        ),
        isNull,
      );
      expect(
        validate(
          '2024-06-14',
          '2024-06-14',
          sourceText: 'DOB: 2024-06-14; Report date: 2026-03-14',
        ),
        isNull,
      );
      expect(
        validate(
          '2026-03-14',
          '2026-03-14',
          sourceText: 'DOB: 2024-06-14; Report date: 2026-03-14',
        ),
        DateTime.utc(2026, 3, 14),
      );
    });

    test('a repeated date in different contexts requires review', () {
      expect(
        validate(
          '2026-03-14',
          '2026-03-14',
          sourceText: 'DOB: 2026-03-14; Report date: 2026-03-14',
        ),
        isNull,
      );
    });
  });

  test(
    'absent numeric fact label is rejected without aborting other facts',
    () {
      const line = SourceLine(
        id: 'synthetic-l1',
        page: 1,
        text: 'Hb 11.2 g/dL',
      );
      final result = validateExtraction(
        jsonEncode({
          'facts': [
            {
              'kind': 'lab',
              'name': 'An absent label longer than its evidence',
              'value': '11.2',
              'unit': 'g/dL',
              'range': '',
              'sourceLineId': line.id,
              'evidence': line.text,
            },
            {
              'kind': 'lab',
              'name': 'Hb',
              'value': '11.2',
              'unit': 'g/dL',
              'range': '',
              'sourceLineId': line.id,
              'evidence': line.text,
            },
          ],
        }),
        [line],
      );
      expect(result.rejected, 1);
      expect(result.facts.single.name, 'Hb');
    },
  );
}
