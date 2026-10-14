import 'package:ayumitra/domain/companion_intent.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Non-midnight local components matter; no conversion to UTC is permitted.
  final now = DateTime(2026, 10, 14, 1, 30);
  Report report(
    String id,
    DateTime? date, {
    String profileId = 'owner',
    DateTime? importedAt,
    bool fallback = false,
  }) => Report(
    id: id,
    profileId: profileId,
    name: '$id.pdf',
    extension: 'pdf',
    digest: 'synthetic-$id',
    importedAt: importedAt ?? DateTime(2026, 10, 14),
    eventDate: date,
    dateIsFallback: fallback,
  );
  final reports = [
    report('march14-a', DateTime.utc(2026, 3, 14)),
    report('march14-b', DateTime.utc(2026, 3, 14)),
    report('march15', DateTime.utc(2026, 3, 15)),
    report('march16', DateTime.utc(2026, 3, 16)),
    report('march17', DateTime.utc(2026, 3, 17)),
    report('april3', DateTime.utc(2026, 4, 3)),
    report('prior-year', DateTime.utc(2025, 3, 14)),
    report('yesterday', DateTime.utc(2026, 10, 13)),
    report('today', DateTime.utc(2026, 10, 14)),
    report('last-week', DateTime.utc(2026, 10, 5)),
    report('last-month', DateTime.utc(2026, 9, 30)),
    report('unknown-date', null),
    report('fallback', DateTime.utc(2026, 10, 14), fallback: true),
    report('future', DateTime.utc(2026, 10, 15)),
    report('other-person', DateTime.utc(2026, 3, 14), profileId: 'other'),
  ];
  List<String> ids(String request) => reportsForRequest(
    reports,
    'owner',
    request,
    now,
  ).map((report) => report.id).toList();

  test('explicit dates retain every match and never another profile', () {
    for (final date in [
      'March 14, 2026',
      '14 March 2026',
      '14th Mar. 2026',
      '2026-03-14',
      '2026/03/14',
      '14/03/2026',
      '03/14/2026',
    ]) {
      expect(ids('What was the value on $date?'), [
        'march14-a',
        'march14-b',
      ], reason: date);
    }
  });

  test('date windows are inclusive of the requested final day', () {
    for (final range in [
      'March 14 to March 16, 2026',
      'March 14 to 16, 2026',
      'March 14, 2026 through March 16, 2026',
      '14 March 2026 to 16 March 2026',
      '2026-03-14 to 2026-03-16',
    ]) {
      expect(ids('Summarize the reports from $range'), [
        'march14-a',
        'march14-b',
        'march15',
        'march16',
      ], reason: range);
    }
  });

  test('separate dates select exact days without filling the gap', () {
    expect(ids('Compare 2026-03-14 and 2026-03-16'), [
      'march14-a',
      'march14-b',
      'march16',
    ]);
  });

  test('explicit years and months select their complete calendar windows', () {
    expect(ids('Show March 2026 reports'), [
      'march14-a',
      'march14-b',
      'march15',
      'march16',
      'march17',
    ]);
    expect(
      ids('Show March 2026 to September 2026 reports'),
      contains('april3'),
    );
    final year = ids('Show reports from 2026');
    expect(year, contains('april3'));
    expect(year, isNot(contains('prior-year')));
    expect(year, isNot(contains('fallback')));
    expect(year, isNot(contains('future')));
  });

  test('today and yesterday use caller local calendar components', () {
    expect(ids('Show reports dated today'), ['today']);
    expect(ids('Show reports dated yesterday'), ['yesterday']);
    expect(ids('Show reports dated today and yesterday'), [
      'yesterday',
      'today',
    ]);
  });

  test('last week and last month mean the preceding calendar period', () {
    expect(ids('Show reports from last week'), ['last-week']);
    expect(ids('Show reports from last month'), ['last-month']);
    expect(ids('Show reports from this month'), [
      'yesterday',
      'today',
      'last-week',
    ]);
  });

  test('filing date is distinct from a clinical event date', () {
    expect(ids('Show reports dated today'), ['today']);
    final filed = ids('Show files uploaded today');
    expect(filed, contains('march14-a'));
    expect(filed, contains('unknown-date'));
    expect(filed, contains('fallback'));
    expect(filed, isNot(contains('other-person')));
  });

  test('ambiguous, invalid and future dates are never silently invented', () {
    expect(ids('Show 03/04/2026 reports'), isEmpty);
    expect(
      reportDateFilterForRequest('Show 03/04/2026 reports', now)!.ambiguous,
      isTrue,
    );
    expect(ids('Show February 30, 2026 reports'), isEmpty);
    expect(ids('Show 2026-10-15 reports'), isEmpty);
    expect(ids('Show March 16 to March 14, 2026 reports'), isEmpty);
  });

  test('unconstrained requests preserve the complete owned candidate set', () {
    expect(reportDateFilterForRequest('Summarize my history', now), isNull);
    expect(ids('Summarize my history'), [
      for (final report in reports)
        if (report.profileId == 'owner') report.id,
    ]);
  });
}
