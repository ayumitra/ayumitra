// Synthetic health-report + agentic-draft checks: scripted model, no network.
import 'dart:convert';

import 'package:ayumitra/services/health_report.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/second_opinion_draft.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubIntelligence implements Intelligence {
  _StubIntelligence(this.script);
  final List<String> script;
  final instructions = <String>[];
  final inputs = <String>[];
  int calls = 0;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    instructions.add(instruction);
    inputs.add(input);
    final index = calls++;
    return index < script.length ? script[index] : script.last;
  }
}

List<Map<String, String>> _evidence() => [
  {
    'sourceId': 'r1/p1-l1',
    'text': 'Report date: 2026-03-14',
    'label': 'CBC report',
  },
  {
    'sourceId': 'r1/p1-l2',
    'text': 'Hemoglobin 11.2 g/dL',
    'label': 'CBC report',
  },
];

void main() {
  for (final healthReport in [true, false]) {
    test(
      '${healthReport ? 'health report' : 'agentic draft'} repairs a source-valid false access refusal using the supplied context',
      () async {
        const refusal = 'I cannot access your records. [S1] [S2]';
        final model = _StubIntelligence([
          refusal,
          '## Findings\nHemoglobin 11.2 g/dL on 2026-03-14 [S2] [S1].',
        ]);
        final output = healthReport
            ? await generateHealthReport(
                model,
                profileName: 'Synthetic',
                evidence: _evidence(),
                request: 'Craft a health report',
              )
            : await generateAgenticDraft(
                model,
                latestRequest: 'Prepare a second-opinion brief',
                evidence: _evidence(),
              );

        expect(model.calls, 2);
        expect(output, contains('Hemoglobin 11.2 g/dL on 2026-03-14'));
        expect(output, contains('[r1/p1-l2]'));
        expect(output, contains('[r1/p1-l1]'));
        expect(output, isNot(contains('cannot access')));
        expect(output, isNot(contains(RegExp(r'\[S\d+\]'))));
        final initial = jsonDecode(model.inputs.first) as Map;
        final repaired = jsonDecode(model.inputs.last) as Map;
        expect(initial, isNot(contains('outputRepair')));
        expect(repaired['evidence'], initial['evidence']);
        expect(initial['evidence'], [
          {
            'sourceId': 'S1',
            'text': 'Report date: 2026-03-14',
            'label': 'CBC report',
          },
          {
            'sourceId': 'S2',
            'text': 'Hemoglobin 11.2 g/dL',
            'label': 'CBC report',
          },
        ]);
        expect(model.instructions.last, contains('OUTPUT REPAIR:'));
        expect(model.instructions.last.toLowerCase(), contains('accessible'));
        expect(
          model.instructions.last.toLowerCase(),
          contains('use them directly'),
        );
        expect(
          (repaired['outputRepair'] as Map)['instruction']
              .toString()
              .toLowerCase(),
          contains('accessible'),
        );
        expect(model.inputs.last, isNot(contains(refusal)));
        expect(model.instructions.last, isNot(contains(refusal)));
      },
    );
  }
  test(
    'health report composes dated findings with canonical citations',
    () async {
      final model = _StubIntelligence([
        '## Health report\nHemoglobin 11.2 g/dL on 2026-03-14 [S2] [S1].',
      ]);
      final report = await generateHealthReport(
        model,
        profileName: 'Synthetic',
        evidence: _evidence(),
        request: 'Craft a health report',
      );

      expect(model.calls, 1);
      expect(report, contains('11.2'));
      expect(report, contains('[r1/p1-l2]'));
      expect(report!.contains(RegExp(r'\[S\d+\]')), isFalse);
    },
  );

  test('health report repairs uncited output within the ten-try cap', () async {
    final model = _StubIntelligence([
      'Hemoglobin looks fine.',
      'Hemoglobin 11.2 g/dL [S2].',
    ]);
    final report = await generateHealthReport(
      model,
      profileName: 'Synthetic',
      evidence: _evidence(),
    );

    expect(model.calls, 2);
    expect(report, contains('[r1/p1-l2]'));
  });

  test('health report returns null with no evidence to compose from', () async {
    final model = _StubIntelligence(['anything']);
    final report = await generateHealthReport(
      model,
      profileName: 'Synthetic',
      evidence: [],
    );

    expect(report, isNull);
    expect(model.calls, 0);
  });

  test('health report cites web and vitals context under own aliases', () async {
    final model = _StubIntelligence([
      '## Health report\nHemoglobin 11.2 g/dL [S2]; general info [S3]; vitals [S4].',
    ]);
    final report = await generateHealthReport(
      model,
      profileName: 'Synthetic',
      evidence: _evidence(),
      webSources: [
        {
          'sourceId': 'web-1',
          'title': 'Hemoglobin info',
          'excerpt': 'Hemoglobin carries oxygen.',
        },
      ],
      vitalsSummary: 'SpO2 98% on 2026-10-01.',
    );

    expect(model.calls, 1);
    expect(report, contains('[r1/p1-l2]'));
    expect(report, contains('[web-1]'));
    expect(report, contains('[vitals]'));
    expect(report!.contains(RegExp(r'\[S\d+\]')), isFalse);
  });

  test('rows without a sourceId fail clearly instead of crashing', () async {
    final model = _StubIntelligence(['anything']);
    await expectLater(
      generateHealthReport(
        model,
        profileName: 'Synthetic',
        evidence: [
          {'text': 'Hemoglobin 11.2 g/dL', 'label': 'CBC report'},
        ],
      ),
      throwsFormatException,
    );
    expect(model.calls, 0);

    await expectLater(
      generateAgenticDraft(
        model,
        latestRequest: 'Summarize',
        evidence: [
          {'text': 'Hemoglobin 11.2 g/dL', 'label': 'CBC report'},
        ],
      ),
      throwsFormatException,
    );
    expect(model.calls, 0);
  });

  test(
    'agentic draft corroborates evidence with canonical citations',
    () async {
      final model = _StubIntelligence([
        '## Request\nHemoglobin?\n## Key evidence\n11.2 g/dL [S2].',
      ]);
      final draft = await generateAgenticDraft(
        model,
        latestRequest: 'What was my hemoglobin?',
        evidence: _evidence(),
      );

      expect(model.calls, 1);
      expect(model.instructions.single, secondOpinionDraftPrompt);
      expect(draft, contains('[r1/p1-l2]'));
      expect(draft!.contains(RegExp(r'\[S\d+\]')), isFalse);
    },
  );

  test(
    'generic request follows the requested format, not brief headings',
    () async {
      final model = _StubIntelligence([
        'To whom it may concern: rest advised on 2026-03-14 [S1].',
      ]);
      final draft = await generateAgenticDraft(
        model,
        latestRequest: 'Draft a school absence note',
        evidence: _evidence().take(1).toList(),
        requestedFormat: 'school absence note',
      );

      expect(model.calls, 1);
      expect(model.instructions.single, freeformDraftPrompt);
      final payload = jsonDecode(model.inputs.single) as Map<String, dynamic>;
      expect(payload['requestedFormat'], 'school absence note');
      expect(draft, contains('[r1/p1-l1]'));
      expect(draft, isNot(contains('## Corroboration and conflicts')));
    },
  );

  test('user history composes a draft with no uploaded report', () async {
    final model = _StubIntelligence([
      'Message for your doctor based on your history [S1].',
    ]);
    final draft = await generateAgenticDraft(
      model,
      latestRequest: 'Prepare a message for my doctor',
      evidence: [],
      history: 'Fever reported on 2026-10-10.',
      requestedFormat: 'message to a doctor',
    );

    expect(model.calls, 1);
    expect(draft, contains('[user-history]'));
    expect(draft!.contains(RegExp(r'\[S\d+\]')), isFalse);
  });

  test('health report composes from history alone, no report needed', () async {
    final model = _StubIntelligence([
      '## Health report\nFever reported on 2026-10-10 [S1].',
    ]);
    final report = await generateHealthReport(
      model,
      profileName: 'Synthetic',
      evidence: [],
      history: 'Fever reported on 2026-10-10.',
    );

    expect(model.calls, 1);
    expect(report, contains('[user-history]'));
    expect(report!.contains(RegExp(r'\[S\d+\]')), isFalse);
  });

  test(
    'date of birth reaches report and draft payloads for exact age math',
    () async {
      final reportModel = _StubIntelligence([
        '## Health report\nBorn 2024-06-01 [S1].',
      ]);
      await generateHealthReport(
        reportModel,
        profileName: 'Synthetic',
        evidence: _evidence().take(1).toList(),
        dateOfBirth: '2024-06-01',
      );
      final reportPayload =
          jsonDecode(reportModel.inputs.single) as Map<String, dynamic>;
      expect(reportPayload['dateOfBirth'], '2024-06-01');

      final draftModel = _StubIntelligence([
        '## Request\nAge?\n## Key evidence\nBorn 2024-06-01 [S1].',
      ]);
      await generateAgenticDraft(
        draftModel,
        latestRequest: 'How old?',
        evidence: _evidence().take(1).toList(),
        dateOfBirth: '2024-06-01',
      );
      final draftPayload =
          jsonDecode(draftModel.inputs.single) as Map<String, dynamic>;
      expect(draftPayload['dateOfBirth'], '2024-06-01');
    },
  );

  test('agentic draft returns null on empty input or repair cap', () async {
    final empty = _StubIntelligence(['anything']);
    expect(
      await generateAgenticDraft(
        empty,
        latestRequest: '  ',
        evidence: _evidence(),
      ),
      isNull,
    );
    expect(empty.calls, 0);

    final capped = _StubIntelligence(List.filled(10, 'bad'));
    expect(
      await generateAgenticDraft(
        capped,
        latestRequest: 'Summarize for a specialist',
        evidence: _evidence(),
      ),
      isNull,
    );
    expect(capped.calls, 10);
  });
}
