// Synthetic Markdown-generation checks: scripted model, no network.
import 'dart:convert';

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubIntelligence implements Intelligence {
  _StubIntelligence(this.script);
  final List<String> script;
  final inputs = <String>[];
  int calls = 0;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    inputs.add(input);
    final index = calls++;
    return index < script.length ? script[index] : script.last;
  }
}

class _BatchIntelligence implements Intelligence {
  _BatchIntelligence(this.respond);
  final String Function(Map<String, dynamic> payload, int call) respond;
  final payloads = <Map<String, dynamic>>[];
  final instructions = <String>[];

  int get calls => payloads.length;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    final payload = jsonDecode(input) as Map<String, dynamic>;
    payloads.add(payload);
    instructions.add(instruction);
    return respond(payload, calls);
  }
}

List<Map<String, dynamic>> _rows(Map<String, dynamic> payload) =>
    (payload['sourceRows'] as List).cast<Map<String, dynamic>>();

String _echoRows(Map<String, dynamic> payload, int _) => _rows(
  payload,
).map((row) => '${row['text']} [${row['sourceId']}]').join('\n');

List<SourceLine> _manyRows(int count) => [
  for (var number = 1; number <= count; number++)
    SourceLine(
      id: 'l$number',
      page: (number - 1) ~/ 24 + 1,
      text: 'Synthetic source row $number',
    ),
];

MedicalFact _fact(String id, String sourceLineId, {required bool corrected}) =>
    MedicalFact(
      id: id,
      kind: 'lab',
      name: 'Synthetic corrected value',
      value: '13.7',
      unit: 'g/dL',
      range: '',
      sourceLineId: sourceLineId,
      evidence: 'Synthetic source evidence',
      corrected: corrected,
    );

Report _report() => Report(
  id: 'r1',
  profileId: 'p',
  name: 'synthetic.txt',
  extension: 'txt',
  digest: 'digest',
  importedAt: DateTime.utc(2026, 3, 15),
  lines: const [
    SourceLine(id: 'p1-l1', page: 1, text: 'Report date: 2026-03-14'),
    SourceLine(id: 'p1-l2', page: 1, text: 'Hemoglobin 11.2 g/dL'),
  ],
);

Profile _owner() => const Profile(id: 'p', name: 'Synthetic', history: '');

void main() {
  test(
    'repairs uncited output and resolves aliases to canonical IDs',
    () async {
      final model = _StubIntelligence([
        'Hemoglobin looks fine.',
        '## Summary\nHemoglobin 11.2 g/dL [S2] on [S1].',
      ]);
      final markdown = await generateReportMarkdown(model, _report(), _owner());

      expect(model.calls, 2);
      expect(markdown, contains('11.2'));
      expect(markdown, contains('[r1/p1-l2]'));
      expect(markdown!.contains(RegExp(r'\[S\d+\]')), isFalse);
    },
  );

  test('cap returns null after three attempts', () async {
    final model = _StubIntelligence(['bad one', 'bad two', 'bad three']);
    final markdown = await generateReportMarkdown(model, _report(), _owner());

    expect(markdown, isNull);
    expect(model.calls, 3);
  });

  test('blank output is rejected and retried', () async {
    final model = _StubIntelligence(['   ', 'Hemoglobin 11.2 g/dL [S2].']);
    final markdown = await generateReportMarkdown(model, _report(), _owner());

    expect(model.calls, 2);
    expect(markdown, contains('[r1/p1-l2]'));
  });

  test('dateless rows send filing-date provenance, category other', () async {
    final model = _StubIntelligence(['Hemoglobin 11.2 g/dL [S1].']);
    final report = Report(
      id: 'r1',
      profileId: 'p',
      name: 'synthetic.txt',
      extension: 'txt',
      digest: 'digest',
      importedAt: DateTime.utc(2026, 3, 15),
      lines: const [
        SourceLine(id: 'p1-l1', page: 1, text: 'Administrative cover sheet'),
      ],
    );
    final markdown = await generateReportMarkdown(model, report, _owner());

    expect(markdown, contains('[r1/p1-l1]'));
    final payload = jsonDecode(model.inputs.single) as Map<String, dynamic>;
    final provenance = payload['dateProvenance'] as Map<String, dynamic>;
    expect(provenance['isFallback'], isTrue);
    expect(payload['category'], 'other');
  });

  test(
    'all rows beyond 80 reach the model including a late clinical value',
    () async {
      final lines = [
        ..._manyRows(96),
        const SourceLine(
          id: 'l97',
          page: 5,
          text: 'Platelets 148 thousand per microliter',
        ),
      ];
      final model = _BatchIntelligence(_echoRows);
      final markdown = await generateReportMarkdown(
        model,
        _report().copy(lines: lines),
        _owner(),
      );

      expect(model.calls, greaterThan(1));
      expect(
        model.payloads.expand(_rows).map((row) => row['text']),
        lines.map((line) => line.text),
      );
      expect(
        model.payloads.every((payload) => _rows(payload).length <= 24),
        isTrue,
      );
      expect(
        markdown,
        contains('Platelets 148 thousand per microliter [r1/l97]'),
      );
      expect(markdown!.contains(RegExp(r'\[S\d+\]')), isFalse);
    },
  );

  test(
    'source text over 400 characters retains its late value intact',
    () async {
      final text =
          '${List.filled(40, 'Synthetic administrative note. ').join()}'
          'Sodium 139.4 mmol/L';
      expect(text.length, greaterThan(400));
      final line = SourceLine(id: 'long', page: 1, text: text);
      final model = _BatchIntelligence(_echoRows);
      final markdown = await generateReportMarkdown(
        model,
        _report().copy(lines: [line]),
        _owner(),
      );

      expect(_rows(model.payloads.single).single['text'], text);
      expect(markdown, contains('Sodium 139.4 mmol/L [r1/long]'));
      expect(line.text, text);
    },
  );

  test(
    'character-heavy batches preserve rows within the source-text budget',
    () async {
      final lines = [
        for (var number = 1; number <= 40; number++)
          SourceLine(
            id: 'heavy-$number',
            page: 1,
            text: '${List.filled(500, 'x').join()} value $number',
          ),
      ];
      final model = _BatchIntelligence(_echoRows);
      await generateReportMarkdown(
        model,
        _report().copy(lines: lines),
        _owner(),
      );

      expect(model.calls, greaterThan(2));
      for (final payload in model.payloads) {
        final rows = _rows(payload);
        expect(rows.length, lessThanOrEqualTo(24));
        expect(
          rows.fold<int>(
            0,
            (count, row) => count + (row['text'] as String).length,
          ),
          lessThanOrEqualTo(8000),
        );
      }
      expect(
        model.payloads.expand(_rows).map((row) => row['text']),
        lines.map((line) => line.text),
      );
    },
  );

  test('a foreign profile owner is refused before any model call', () async {
    final model = _BatchIntelligence(_echoRows);
    await expectLater(
      generateReportMarkdown(
        model,
        _report(),
        const Profile(id: 'foreign-person', name: 'Other person', history: ''),
      ),
      throwsA(isA<StateError>()),
    );
    expect(model.calls, 0);
  });

  test(
    'aliases reset per batch and canonical references cannot cross batches',
    () async {
      String? firstBatchText;
      final attemptsByBatch = <String, int>{};
      final model = _BatchIntelligence((payload, call) {
        final rows = _rows(payload);
        final firstText = rows.first['text'] as String;
        firstBatchText ??= firstText;
        final attempt = attemptsByBatch.update(
          firstText,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        if (firstText == firstBatchText) {
          return 'First source [r1/l1].\n${_echoRows(payload, call)}';
        }
        if (attempt == 1) return 'Cross-batch source [r1/l1].';
        return _echoRows(payload, call);
      });
      final markdown = await generateReportMarkdown(
        model,
        _report().copy(lines: _manyRows(49)),
        _owner(),
      );

      expect(attemptsByBatch.length, greaterThan(1));
      expect(attemptsByBatch.values.first, 1);
      expect(
        attemptsByBatch.values.skip(1).every((count) => count == 2),
        isTrue,
      );
      expect(
        model.payloads.every(
          (payload) => _rows(payload).first['sourceId'] == 'S1',
        ),
        isTrue,
      );
      expect(markdown, contains('[r1/l49]'));
      expect(markdown, isNot(contains('Cross-batch source')));
      expect(markdown!.contains(RegExp(r'\[S\d+\]')), isFalse);
    },
  );

  test(
    'one failed batch hits its three-attempt cap and discards the whole draft',
    () async {
      String? firstBatchText;
      final model = _BatchIntelligence((payload, call) {
        final firstText = _rows(payload).first['text'] as String;
        firstBatchText ??= firstText;
        return firstText == firstBatchText
            ? _echoRows(payload, call)
            : 'Unknown source [foreign-report/foreign-line].';
      });
      final markdown = await generateReportMarkdown(
        model,
        _report().copy(lines: _manyRows(49)),
        _owner(),
      );

      expect(markdown, isNull);
      expect(model.calls, 4);
      expect(
        model.payloads
            .skip(1)
            .map((payload) => _rows(payload).first['text'])
            .toSet()
            .length,
        1,
      );
    },
  );

  test(
    'oversized single rows fail clearly before generation without changing source',
    () async {
      final text = List.filled(8001, 'x').join();
      final report = _report().copy(
        lines: [
          ..._manyRows(25),
          SourceLine(id: 'oversized', page: 2, text: text),
        ],
      );
      final model = _BatchIntelligence(_echoRows);
      await expectLater(
        generateReportMarkdown(model, report, _owner()),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'clear original-preservation message',
            allOf(contains('source row'), contains('original remains saved')),
          ),
        ),
      );
      expect(model.calls, 0);
      expect(report.lines.last.text, text);
    },
  );

  test(
    'only human corrections with source rows in that batch are supplied',
    () async {
      final model = _BatchIntelligence(_echoRows);
      final report = _report().copy(
        lines: _manyRows(49),
        facts: [
          _fact('early-correction', 'l1', corrected: true),
          _fact('late-correction', 'l49', corrected: true),
          _fact('uncorrected-model-fact', 'l2', corrected: false),
          _fact('orphan-correction', 'not-an-owned-row', corrected: true),
        ],
      );
      await generateReportMarkdown(model, report, _owner());

      final correctionIds = <String>[];
      for (final payload in model.payloads) {
        expect(payload.containsKey('facts'), isFalse);
        final rowAliases = _rows(payload).map((row) => row['sourceId']).toSet();
        final sourceLineIds = _rows(payload)
            .map(
              (row) => (row['text'] as String).replaceFirst(
                'Synthetic source row ',
                'l',
              ),
            )
            .toSet();
        final corrections = (payload['userCorrections'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        for (final correction in corrections) {
          correctionIds.add(correction['id'] as String);
          expect(rowAliases, contains(correction['sourceId']));
          expect(sourceLineIds, contains(correction['sourceLineId']));
          expect(correction['corrected'], isTrue);
        }
      }
      expect(correctionIds, ['early-correction', 'late-correction']);
    },
  );
}
