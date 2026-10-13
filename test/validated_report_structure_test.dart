import 'dart:convert';

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/validated_report_structure.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedIntelligence implements Intelligence {
  _ScriptedIntelligence(this.replies);

  final List<Object> replies;
  final List<Map<String, dynamic>> inputs = [];
  final List<String> instructions = [];

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    final reply = replies[inputs.length];
    inputs.add(jsonDecode(input) as Map<String, dynamic>);
    instructions.add(instruction);
    if (reply is Exception || reply is Error) throw reply;
    return reply as String;
  }
}

const _lines = [
  SourceLine(id: 'D1', page: 1, text: 'Report date: 2026-03-14'),
  SourceLine(id: 'L1', page: 1, text: 'Hemoglobin 11.2 g/dL range 11-15'),
  SourceLine(id: 'B1', page: 1, text: 'DOB: 2020-01-15'),
  SourceLine(id: 'A1', page: 1, text: 'Report date: 03/04/2026'),
];
final _now = DateTime(2026, 10, 13);

String _organization({
  Object? type = 'lab',
  Object? date = '2026-03-14',
  Object? evidence = 'Report date: 2026-03-14',
  Object? sourceId = 'D1',
}) => jsonEncode({
  'type': type,
  'eventDate': date,
  'dateEvidence': evidence,
  'dateSourceLineId': sourceId,
});

String _extraction({String value = '11.2', String sourceId = 'L1'}) =>
    jsonEncode({
      'facts': [
        {
          'kind': 'lab',
          'name': 'Hemoglobin',
          'value': value,
          'unit': 'g/dL',
          'range': '11-15',
          'sourceLineId': sourceId,
          'evidence': 'Hemoglobin 11.2 g/dL range 11-15',
        },
      ],
    });

void main() {
  test('fenced organizer JSON preserves the supported clinical date', () async {
    final model = _ScriptedIntelligence(['```json\n${_organization()}\n```']);
    final result = await generateValidatedReportOrganization(
      intelligence: model,
      lines: _lines,
      now: _now,
    );
    expect(result.type, 'lab');
    expect(result.eventDate, DateTime.utc(2026, 3, 14));
    expect(model.inputs, hasLength(1));
    expect(model.instructions.single, organizerPrompt);
  });

  test('unknown dates accept omitted legacy source ID only', () async {
    final model = _ScriptedIntelligence([
      jsonEncode({'type': 'note', 'eventDate': null, 'dateEvidence': null}),
    ]);
    final result = await generateValidatedReportOrganization(
      intelligence: model,
      lines: _lines,
      now: _now,
    );
    expect(result.type, 'note');
    expect(result.eventDate, isNull);
    expect(model.inputs, hasLength(1));
  });

  test(
    'repair preserves source rows without echoing discarded output',
    () async {
      const marker = 'REJECTED_OUTPUT_PRIVATE_MARKER';
      final model = _ScriptedIntelligence([
        '$marker invalid JSON',
        _organization(type: 'invented-category'),
        _organization(),
      ]);
      final statuses = <String>[];
      final result = await generateValidatedReportOrganization(
        intelligence: model,
        lines: _lines,
        now: _now,
        status: statuses.add,
      );
      expect(result.eventDate, DateTime.utc(2026, 3, 14));
      expect(model.inputs, hasLength(3));
      expect(statuses, [
        'Repair report organization format (2/3)…',
        'Repair report organization format (3/3)…',
      ]);
      for (final input in model.inputs) {
        expect(
          input['sourceLines'],
          _lines.map((line) => line.toJson()).toList(),
        );
        expect(jsonEncode(input), isNot(contains(marker)));
        expect(jsonEncode(input), isNot(contains('invented-category')));
      }
      expect(model.inputs.first.containsKey('outputRepair'), false);
      expect(model.inputs.last['outputRepair'], isA<Map>());
    },
  );

  test('incomplete date provenance is repaired rather than accepted', () async {
    final model = _ScriptedIntelligence([
      jsonEncode({
        'type': 'lab',
        'eventDate': '2026-03-14',
        'dateEvidence': 'Report date: 2026-03-14',
      }),
      _organization(date: null, evidence: null, sourceId: null),
    ]);
    final result = await generateValidatedReportOrganization(
      intelligence: model,
      lines: _lines,
      now: _now,
    );
    expect(result.eventDate, isNull);
    expect(model.inputs, hasLength(2));
  });

  for (final proposal in <String, String>{
    'birth date': _organization(
      date: '2020-01-15',
      evidence: '2020-01-15',
      sourceId: 'B1',
    ),
    'ambiguous numeric date': _organization(
      date: '2026-04-03',
      evidence: 'Report date: 03/04/2026',
      sourceId: 'A1',
    ),
    'future date': _organization(date: '2027-03-14'),
    'unknown source': _organization(sourceId: 'NOT_A_SOURCE'),
    'unsupported quotation': _organization(evidence: 'Invented report date'),
  }.entries) {
    test('${proposal.key} stays unknown without medical inference', () async {
      final model = _ScriptedIntelligence([proposal.value]);
      final result = await generateValidatedReportOrganization(
        intelligence: model,
        lines: _lines,
        now: _now,
      );
      expect(result.eventDate, isNull);
      expect(model.inputs, hasLength(1));
    });
  }

  test(
    'organizer malformed structure stops after three local attempts',
    () async {
      final model = _ScriptedIntelligence(['[]', '{}', 'not JSON']);
      await expectLater(
        generateValidatedReportOrganization(
          intelligence: model,
          lines: _lines,
          now: _now,
        ),
        throwsFormatException,
      );
      expect(model.inputs, hasLength(3));
    },
  );

  test('generation-time FormatException propagates without retry', () async {
    final failure = const FormatException('Local context limit');
    final model = _ScriptedIntelligence([failure]);
    await expectLater(
      generateValidatedReportOrganization(
        intelligence: model,
        lines: _lines,
        now: _now,
      ),
      throwsA(same(failure)),
    );
    expect(model.inputs, hasLength(1));
  });

  test(
    'extraction repairs malformed JSON and retains exact evidence',
    () async {
      final model = _ScriptedIntelligence([
        'PRIVATE_INVALID_OUTPUT',
        '{"facts":"wrong shape"}',
        '```json\n${_extraction()}\n```',
      ]);
      final result = await generateValidatedReportExtraction(
        intelligence: model,
        lines: _lines,
      );
      expect(result.facts.single.value, '11.2');
      expect(result.facts.single.sourceLineId, 'L1');
      expect(result.rejected, 0);
      expect(model.inputs, hasLength(3));
      expect(
        model.instructions.every((value) => value == extractorPrompt),
        true,
      );
      for (final input in model.inputs) {
        expect(
          input['sourceLines'],
          _lines.map((line) => line.toJson()).toList(),
        );
        expect(jsonEncode(input), isNot(contains('PRIVATE_INVALID_OUTPUT')));
      }
    },
  );

  test(
    'unsupported extraction value is excluded rather than fabricated',
    () async {
      final model = _ScriptedIntelligence([_extraction(value: '15')]);
      final result = await generateValidatedReportExtraction(
        intelligence: model,
        lines: _lines,
      );
      expect(result.facts, isEmpty);
      expect(result.rejected, 1);
      expect(model.inputs, hasLength(1));
    },
  );

  test('extraction cannot use an invented source ID', () async {
    final model = _ScriptedIntelligence([_extraction(sourceId: 'FOREIGN')]);
    final result = await generateValidatedReportExtraction(
      intelligence: model,
      lines: _lines,
    );
    expect(result.facts, isEmpty);
    expect(result.rejected, 1);
  });

  test('malformed extraction stops after three local attempts', () async {
    final model = _ScriptedIntelligence(['{}', '[]', '{"facts":null}']);
    await expectLater(
      generateValidatedReportExtraction(intelligence: model, lines: _lines),
      throwsFormatException,
    );
    expect(model.inputs, hasLength(3));
  });

  test(
    'extraction runtime failure propagates without structural retry',
    () async {
      final failure = StateError('Native runtime unavailable');
      final model = _ScriptedIntelligence([failure]);
      await expectLater(
        generateValidatedReportExtraction(intelligence: model, lines: _lines),
        throwsA(same(failure)),
      );
      expect(model.inputs, hasLength(1));
    },
  );
}
