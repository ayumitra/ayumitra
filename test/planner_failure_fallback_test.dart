import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/agent_plan.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:ayumitra/services/local_research.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _BrokenPlanner extends LocalIntelligence {
  _BrokenPlanner(this.plan);
  final String plan;
  List<String> repairedPlans = [];
  bool incompleteGeneration = false;
  bool invalidAnswer = false;
  int researchCalls = 0;
  final plannerInputs = <Map>[];
  final summaries = <Map>[];
  @override
  bool get available => true;
  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == reportMarkdownPrompt ||
        instruction.startsWith('$reportMarkdownPrompt\n\nOUTPUT REPAIR:')) {
      final data = jsonDecode(input) as Map;
      final row = (data['sourceRows'] as List).cast<Map>().first;
      return '${row['text']} [${row['sourceId']}].';
    }
    if (instruction == organizerPrompt) return '{"type":"lab"}';
    if (instruction == extractorPrompt) return '{"facts":[]}';
    if (instruction == plannerPrompt) {
      plannerInputs.add(jsonDecode(input) as Map);
      if (incompleteGeneration) {
        throw const FormatException('Synthetic incomplete response');
      }
      final repairIndex = plannerInputs.length - 2;
      if (repairIndex >= 0 && repairIndex < repairedPlans.length) {
        return repairedPlans[repairIndex];
      }
      return plan;
    }
    if (instruction == researchPlannerPrompt) {
      researchCalls++;
      return '{"actions":[{"action":"finish"}]}';
    }
    final data = jsonDecode(input) as Map;
    summaries.add(data);
    if (invalidAnswer) return 'Hemoglobin is 11.2 g/dL [invented-source].';
    final row = (data['evidence'] as List).cast<Map>().single;
    return 'Hemoglobin is 11.2 g/dL [${row['sourceId']}].';
  }
}

class _WebRecorder extends WebSearch {
  int calls = 0;
  @override
  bool get available => true;
  @override
  Future<List<WebSource>> search(String query) async {
    calls++;
    return [];
  }
}

Future<AppController> _ready(
  bool browser,
  _BrokenPlanner model,
  _WebRecorder web,
) async {
  final AppController controller;
  if (browser) {
    final demo = DemoController(intelligence: model, webSearch: web);
    await demo.initialize();
    controller = demo;
  } else {
    final directory = await Directory.systemTemp.createTemp(
      'ayumitra-planner-fallback-',
    );
    controller = AppController(intelligence: model, webSearch: web)
      ..loaded = true
      ..vault = EncryptedVault(
        directory: directory,
        key: await AesGcm.with256bits().newSecretKey(),
      );
    addTearDown(() => directory.delete(recursive: true));
  }
  addTearDown(controller.dispose);
  await controller.createProfile('Synthetic Owner', DateTime(2000), '', false);
  if (browser) {
    await (controller as DemoController).importBytes(
      'Owned hemoglobin.txt',
      'txt',
      Uint8List.fromList(utf8.encode('Hemoglobin 11.2 g/dL')),
    );
  } else {
    controller.data = controller.data.copy(
      reports: [
        Report(
          id: 'owned-report',
          profileId: controller.profile!.id,
          name: 'Owned hemoglobin.txt',
          extension: 'txt',
          digest: 'synthetic-owned',
          importedAt: DateTime.utc(2026, 10, 13),
          lines: const [
            SourceLine(id: 'p1-l1', page: 1, text: 'Hemoglobin 11.2 g/dL'),
          ],
        ),
      ],
    );
  }
  controller.data = controller.data.copy(
    reports: [
      ...controller.data.reports,
      Report(
        id: 'foreign-report',
        profileId: 'foreign-profile',
        name: 'FOREIGN_PRIVATE_REPORT',
        extension: 'txt',
        digest: 'synthetic-foreign',
        importedAt: DateTime.utc(2026, 10, 13),
        lines: const [
          SourceLine(
            id: 'p1-l1',
            page: 1,
            text: 'Hemoglobin 99 FOREIGN_PRIVATE_MARKER',
          ),
        ],
      ),
    ],
  );
  return controller;
}

void main() {
  const malformed = {
    'string action array':
        '{"actions":["web_search","What is the typical range for hemoglobin levels?"]}',
    'unknown tool beside extended thinking':
        '{"actions":[{"action":"extended_thinking","query":""},{"action":"upload_records","query":"https://evil.example"}]}',
    'extra endpoint argument':
        '{"actions":[{"action":"search_records","query":"hemoglobin","url":"https://evil.example"}]}',
  };
  for (final browser in [false, true]) {
    for (final entry in malformed.entries) {
      test(
        '${browser ? 'browser' : 'native'} ${entry.key} falls back to owned local evidence without web authorization',
        () async {
          final model = _BrokenPlanner(entry.value);
          final web = _WebRecorder();
          final controller = await _ready(browser, model, web);
          const question = 'What is my hemoglobin value and unit?';
          await controller.ask(question);
          final answer = controller.messages.last;
          expect(answer.text, contains('Hemoglobin is 11.2 g/dL'));
          expect(answer.text, contains('invalid format'));
          expect(
            answer.text,
            contains('rejected plan did not authorize any web tools'),
          );
          expect(answer.hits.length, 1);
          expect(answer.hits.single.report.profileId, controller.profile!.id);
          expect(answer.text, contains('[${answer.hits.single.citation}]'));
          expect(answer.web, isEmpty);
          expect(web.calls, 0);
          expect(model.researchCalls, 0);
          expect(model.plannerInputs.length, 3);
          expect(model.plannerInputs.first.containsKey('outputRepair'), false);
          for (final repair in model.plannerInputs.skip(1)) {
            expect(repair['userRequest'], question);
            expect(
              repair['recentUserRequests'],
              model.plannerInputs.first['recentUserRequests'],
            );
            expect(
              repair['webSearchAvailable'],
              model.plannerInputs.first['webSearchAvailable'],
            );
            expect(
              (repair['outputRepair'] as Map)['expectedSchema'],
              agentPlanSchema,
            );
            expect(jsonEncode(repair), isNot(contains('https://evil.example')));
          }
          expect(controller.stepLog, contains('Retry tool plan (2/3)…'));
          expect(controller.stepLog, contains('Retry tool plan (3/3)…'));
          expect(model.summaries.length, 1);
          expect(
            jsonEncode(model.summaries.single),
            isNot(contains('FOREIGN_PRIVATE')),
          );
          expect(
            controller.stepLog,
            contains('Planner format unavailable · checking saved reports…'),
          );
          expect(
            controller.activeSession!.turns
                .where((turn) => turn.role == 'user')
                .single
                .text,
            question,
          );
          expect(controller.failure, isNull);
          expect(controller.busy, false);
        },
      );
    }
    test(
      '${browser ? 'browser' : 'native'} repairs an invalid first plan using controlled structure feedback',
      () async {
        const rejected = '{"actions":["ATTACKER_OUTPUT_DO_NOT_ECHO"]}';
        final model = _BrokenPlanner(rejected)
          ..repairedPlans = [
            '{"actions":[{"action":"search_records","query":"hemoglobin"}]}',
          ];
        final web = _WebRecorder();
        final controller = await _ready(browser, model, web);
        const question = 'What is my hemoglobin value and unit?';
        await controller.ask(question);
        expect(model.plannerInputs.length, 2);
        final original = model.plannerInputs.first;
        final repaired = model.plannerInputs.last;
        expect(original.containsKey('outputRepair'), false);
        for (final field in [
          'userRequest',
          'recentUserRequests',
          'webSearchAvailable',
        ]) {
          expect(repaired[field], original[field]);
        }
        final feedback = repaired['outputRepair'] as Map;
        expect(feedback['expectedSchema'], agentPlanSchema);
        expect(
          validateAgentPlan(jsonEncode(feedback['correctExample'])).single.tool,
          'search_records',
        );
        expect(feedback['validationFailure'], contains('no extra arguments'));
        expect(
          jsonEncode(repaired),
          isNot(contains('ATTACKER_OUTPUT_DO_NOT_ECHO')),
        );
        expect(controller.stepLog, contains('Retry tool plan (2/3)…'));
        expect(controller.stepLog, isNot(contains('Retry tool plan (3/3)…')));
        final answer = controller.messages.last;
        expect(answer.text, contains('Hemoglobin is 11.2 g/dL'));
        expect(answer.text, contains('[${answer.hits.single.citation}]'));
        expect(answer.text, isNot(contains('invalid format')));
        expect(jsonEncode(model.summaries), isNot(contains('FOREIGN_PRIVATE')));
        expect(web.calls, 0);
        expect(model.researchCalls, 0);
        expect(controller.failure, isNull);
        expect(controller.busy, false);
      },
    );
    test(
      '${browser ? 'browser' : 'native'} citation fallback preserves the exhausted-plan explanation',
      () async {
        final model = _BrokenPlanner(malformed.values.first)
          ..invalidAnswer = true;
        final controller = await _ready(browser, model, _WebRecorder());
        await controller.ask('What is my hemoglobin value and unit?');
        expect(model.plannerInputs.length, 3);
        expect(
          controller.messages.last.text,
          contains('Retrieved evidence · fallback'),
        );
        expect(controller.messages.last.text, contains('after three attempts'));
        expect(
          controller.messages.last.text,
          contains('rejected plan did not authorize any web tools'),
        );
        expect(
          controller.messages.last.hits.single.report.profileId,
          controller.profile!.id,
        );
        expect(controller.failure, isNull);
      },
    );
    test(
      '${browser ? 'browser' : 'native'} incomplete generation is not mistaken for a validated-format failure',
      () async {
        final model = _BrokenPlanner(malformed.values.first)
          ..incompleteGeneration = true;
        final web = _WebRecorder();
        final controller = await _ready(browser, model, web);
        await controller.ask('What is my hemoglobin value?');
        expect(controller.failure, isNotNull);
        expect(
          controller.stepLog,
          isNot(
            contains('Planner format unavailable · checking saved reports…'),
          ),
        );
        expect(model.summaries, isEmpty);
        expect(model.plannerInputs.length, 1);
        expect(controller.stepLog, isNot(contains('Retry tool plan (2/3)…')));
        expect(web.calls, 0);
        expect(model.researchCalls, 0);
        expect(controller.busy, false);
      },
    );
  }
}
