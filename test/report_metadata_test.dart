// Synthetic report-metadata discovery checks. No models, no network.
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/report_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 10, 13);

SourceLine _line(String id, String text) =>
    SourceLine(id: id, page: 1, text: text);

void main() {
  test('single ISO date with a report label is clinical', () {
    final found = discoverReportDate([
      _line('p1-l1', 'Report date: 2026-03-14'),
      _line('p1-l2', 'Hemoglobin 11.2 g/dL'),
    ], now: _now);
    expect(found.date, DateTime.utc(2026, 3, 14));
    expect(found.isFallback, isFalse);
    expect(found.sourceLineId, 'p1-l1');
  });

  test('named and unambiguous numeric dates are accepted', () {
    final named = discoverReportDate([
      _line('p1-l1', 'Collected 14 March 2026'),
    ], now: _now);
    expect(named.date, DateTime.utc(2026, 3, 14));
    expect(named.isFallback, isFalse);

    final numeric = discoverReportDate([
      _line('p1-l1', 'Visit 13/04/2026'),
    ], now: _now);
    expect(numeric.date, DateTime.utc(2026, 4, 13));
    expect(numeric.isFallback, isFalse);
  });

  test('birth dates are never accepted', () {
    final found = discoverReportDate([
      _line('p1-l1', 'DOB: 2020-01-15'),
    ], now: _now);
    expect(found.isFallback, isTrue);
    expect(found.date, DateTime.utc(2026, 10, 13));
    expect(found.sourceLineId, isNull);
  });

  test('several distinct dates fall back to the filing day', () {
    final found = discoverReportDate([
      _line('p1-l1', 'Visit 2026-03-14'),
      _line('p1-l2', 'Follow-up 2026-04-02'),
    ], now: _now);
    expect(found.isFallback, isTrue);
    expect(found.date, DateTime.utc(2026, 10, 13));
  });

  test('repeated rows with the same date remain one clinical date', () {
    final found = discoverReportDate([
      _line('p1-l1', 'Report date: 2026-03-14'),
      _line('p1-l2', 'Collected 14 March 2026'),
      _line('p1-l3', 'Report date: 2026-03-14'),
    ], now: _now);
    expect(found.date, DateTime.utc(2026, 3, 14));
    expect(found.isFallback, isFalse);
    expect(found.sourceLineId, 'p1-l1');
  });

  test(
    'two grouped images with consistent report dates retain date provenance',
    () {
      final found = discoverReportDate(const [
        SourceLine(id: 'p1-l1', page: 1, text: 'Report date: 2026-03-14'),
        SourceLine(id: 'p1-l2', page: 1, text: 'Hemoglobin 11.2 g/dL'),
        SourceLine(id: 'p2-l1', page: 2, text: 'Reported 14 March 2026'),
        SourceLine(
          id: 'p2-l2',
          page: 2,
          text: 'Platelets 148 thousand per microliter',
        ),
      ], now: _now);
      expect(found.date, DateTime.utc(2026, 3, 14));
      expect(found.isFallback, isFalse);
      expect(found.sourceLineId, 'p1-l1');
    },
  );

  test('dateless and future-dated rows fall back', () {
    final dateless = discoverReportDate([
      _line('p1-l1', 'Hemoglobin 11.2 g/dL'),
    ], now: _now);
    expect(dateless.isFallback, isTrue);

    final future = discoverReportDate([
      _line('p1-l1', 'Report date: 2099-01-01'),
    ], now: _now);
    expect(future.isFallback, isTrue);
  });

  test('ambiguous all-small numeric dates fall back', () {
    final found = discoverReportDate([
      _line('p1-l1', 'Date 03/04/2026'),
    ], now: _now);
    expect(found.isFallback, isTrue);
  });

  test('categories come from source content, default other', () {
    String categoryOf(String text) =>
        discoverReportCategory([_line('p1-l1', text)]);
    expect(categoryOf('Hemoglobin 11.2 g/dL, CBC'), 'lab');
    expect(categoryOf('Discharge summary, admitted for fever'), 'discharge');
    expect(categoryOf('Chest X-ray, no acute findings'), 'radiology');
    expect(categoryOf('Prescription refill, pharmacy pickup'), 'prescription');
    expect(categoryOf('Vaccination record: MMR dose'), 'vaccination');
    expect(categoryOf('Growth chart, height 120 cm'), 'growth');
    expect(categoryOf('Random administrative notes'), 'other');
  });
}
