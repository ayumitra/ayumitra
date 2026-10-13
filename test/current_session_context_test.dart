import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _ContextModel extends LocalIntelligence {
  final inputs = <Map>[];
  final plannerInputs = <Map>[];
  bool conversationPlan = false;
  bool omitUserReferenceOnce = false;
  @override
  bool get available => true;
  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == plannerPrompt) {
      plannerInputs.add(jsonDecode(input) as Map);
      if (conversationPlan) {
        return '{"actions":[{"action":"conversation","query":""}]}';
      }
      return '{"actions":[{"action":"search_records","query":"hemoglobin"}]}';
    }
    final payload = jsonDecode(input) as Map;
    inputs.add(payload);
    final context = payload['currentSessionUserContext'] as Map?;
    final evidenceRows = (payload['evidence'] as List).cast<Map>();
    final evidence = evidenceRows.firstOrNull;
    final reportSource = evidence?['sourceId'];
    if (omitUserReferenceOnce) {
      omitUserReferenceOnce = false;
      return 'Historical report finding [$reportSource].';
    }
    if (context != null &&
        (context['text'] as String).contains('was 13') &&
        !(payload['question'] as String).contains('March 14')) {
      final corroborated =
          evidence != null &&
          ((evidence['facts'] as List).single as Map)['value'] == '13' &&
          (context['text'] as String).contains('2026-03-14');
      return 'You reported hemoglobin was 13, unverified [${context['sourceId']}]. '
          '${corroborated ? 'The report corroborates 13 [$reportSource].' : 'Do you have a report for this new value?'} ASSISTANT_ONLY_7777';
    }
    if (evidence == null) {
      throw StateError('A request cannot support its own answer.');
    }
    return 'The dated report records ${((evidence['facts'] as List).single as Map)['value']} g/dL '
        '[${evidence['sourceId']}]. ASSISTANT_ONLY_7777';
  }
}

Report _report(String id, String owner, String value) => Report(
  id: id,
  profileId: owner,
  name: 'March report',
  extension: 'txt',
  digest: id,
  importedAt: DateTime.utc(2026, 3, 14),
  eventDate: DateTime.utc(2026, 3, 14),
  lines: [SourceLine(id: 'p1-l1', page: 1, text: 'Hemoglobin $value g/dL')],
  facts: [
    MedicalFact(
      id: '$id-fact',
      kind: 'lab',
      name: 'Hemoglobin',
      value: value,
      unit: 'g/dL',
      range: '',
      sourceLineId: 'p1-l1',
      evidence: 'Hemoglobin $value g/dL',
    ),
  ],
);

Future<AppController> _ready(bool browser, _ContextModel model) async {
  final AppController controller;
  if (browser) {
    controller = DemoController(intelligence: model);
    await controller.initialize();
  } else {
    final directory = await Directory.systemTemp.createTemp(
      'ayumitra-chat-context-',
    );
    controller = AppController(intelligence: model)
      ..loaded = true
      ..vault = EncryptedVault(
        directory: directory,
        key: await AesGcm.with256bits().newSecretKey(),
      );
    addTearDown(() => directory.delete(recursive: true));
  }
  addTearDown(controller.dispose);
  await controller.createProfile('Synthetic A', DateTime(2000), '', false);
  controller.data = controller.data.copy(
    reports: [_report('report-a', controller.profile!.id, '11.2')],
  );
  return controller;
}

void main() {
  for (final browser in [false, true]) {
    test(
      '${browser ? 'browser' : 'native'} an omitted observation reference triggers structure repair before persistence',
      () async {
        final model = _ContextModel()..omitUserReferenceOnce = true;
        final controller = await _ready(browser, model);
        await controller.ask('hemoglobal was 13');
        expect(model.inputs, hasLength(2));
        expect(model.inputs.first.containsKey('outputRepair'), isFalse);
        expect(model.inputs.last['outputRepair'], isNotNull);
        expect(model.inputs.last['evidence'], model.inputs.first['evidence']);
        expect(
          controller.messages.last.text,
          contains('[conversation:${controller.activeSessionId}]'),
        );
        expect(controller.messages.last.text, contains('Do you have a report'));
        expect(controller.messages.last.hits, isEmpty);
        expect(
          controller.activeSession!.turns.where((t) => t.role == 'assistant'),
          hasLength(1),
        );
        expect(
          controller.messages.last.text,
          isNot(contains('Historical report finding')),
        );
      },
    );
    test(
      '${browser ? 'browser' : 'native'} requests alone are not findings but a reportless update is immediately saved and citable',
      () async {
        final model = _ContextModel();
        final controller = await _ready(browser, model);
        controller.data = controller.data.copy(reports: []);
        await controller.ask('Research my child lab results in depth');
        expect(model.inputs, isEmpty);
        expect(
          controller.messages.last.text,
          contains('couldn’t find supporting information'),
        );
        await controller.newConversation();
        await controller.ask('What is my latest hemoglobin value?');
        expect(model.inputs, isEmpty);
        await controller.ask('hemoglobal was 13');
        expect(model.inputs, hasLength(1));
        final context = model.inputs.single['currentSessionUserContext'] as Map;
        expect(context['text'], contains('hemoglobal was 13'));
        expect(context['text'], isNot(contains('What is my latest')));
        expect((context['currentTurn'] as Map)['kind'], 'user_statement');
        expect(
          controller.messages.last.text,
          contains('[conversation:${controller.activeSession!.id}]'),
        );
        expect(controller.messages.last.text, contains('Do you have a report'));
        expect(controller.messages.last.hits, isEmpty);
        expect(
          controller.data.memories.last.text,
          contains('hemoglobal was 13'),
        );
        expect(controller.failure, isNull);
      },
    );
    test(
      '${browser ? 'browser' : 'native'} current user observations are citable, durable, scoped, and leave reports intact',
      () async {
        final model = _ContextModel();
        final controller = await _ready(browser, model);
        final ownerA = controller.profile!.id;
        await controller.ask('hemoglobal was 13');
        final sessionId = controller.activeSession!.id;
        final firstContext =
            model.inputs.single['currentSessionUserContext'] as Map;
        expect(firstContext['text'], contains('hemoglobal was 13'));
        expect(
          (firstContext['currentTurn'] as Map)['providedAt'],
          controller.activeSession!.turns.first.createdAt.toIso8601String(),
        );
        expect(controller.messages.last.text, contains('Do you have a report'));
        expect(controller.messages.last.hits, isEmpty);
        await controller.ask('What is my latest hemoglobin value?');
        final input = model.inputs.last;
        final context = input['currentSessionUserContext'] as Map;
        expect(context['text'], contains('hemoglobal was 13'));
        expect(context['text'], isNot(contains('ASSISTANT_ONLY_7777')));
        expect(
          context['text'],
          isNot(contains('What is my latest hemoglobin value?')),
        );
        expect((context['text'] as String).length, lessThanOrEqualTo(1800));
        expect(context['status'], contains('unverified'));
        expect(context['status'], contains('questions are requests'));
        expect(
          context['clinicalDateStatus'],
          contains('otherwise use that turn’s providedAt date'),
        );
        final userTurns = (context['userTurns'] as List).cast<Map>();
        expect(
          userTurns.first['providedAt'],
          controller.activeSession!.turns.first.createdAt.toIso8601String(),
        );
        expect(
          DateTime.parse(input['currentDateTime'] as String),
          isA<DateTime>(),
        );
        expect(
          model.plannerInputs.last['currentDateTime'],
          input['currentDateTime'],
        );
        final answer = controller.messages.last;
        expect(answer.text, contains('[conversation:$sessionId]'));
        expect(answer.text, contains('unverified'));
        expect(answer.text, isNot(contains('[report-a/p1-l1]')));
        expect(answer.hits, isEmpty);
        expect(controller.activeSession!.turns.last.text, answer.text);
        expect(
          controller.data.memories.single.text,
          contains('hemoglobal was 13'),
        );
        expect(
          controller.data.memories.single.text,
          isNot(contains('ASSISTANT_ONLY_7777')),
        );
        expect(controller.reports.single.facts.single.value, '11.2');
        expect(controller.reports.single.facts.single.corrected, false);
        if (!browser) {
          final saved = await controller.vault.read();
          expect(
            saved.sessions.single.turns.last.text,
            contains('[conversation:$sessionId]'),
          );
          expect(saved.memories.single.text, contains('hemoglobal was 13'));
          final ciphertext = latin1.decode(
            await File(
              '${controller.vault.directory.path}/index.enc',
            ).readAsBytes(),
          );
          expect(ciphertext, isNot(contains('hemoglobal was 13')));
        }

        await controller.ask('What did the March 14 hemoglobin report say?');
        final dated = model.inputs.last;
        final evidence = (dated['evidence'] as List).cast<Map>().single;
        expect(
          evidence['eventDate'],
          DateTime.utc(2026, 3, 14).toIso8601String(),
        );
        expect(((evidence['facts'] as List).single as Map)['value'], '11.2');
        expect(
          controller.messages.last.text,
          contains('11.2 g/dL [report-a/p1-l1]'),
        );
        expect(controller.reports.single.facts.single.value, '11.2');

        await controller.createProfile(
          'Synthetic B',
          DateTime(2001),
          '',
          false,
        );
        final ownerB = controller.profile!.id;
        controller.data = controller.data.copy(
          reports: [
            ...controller.data.reports,
            _report('report-b', ownerB, '8'),
          ],
        );
        await controller.ask('What is my latest hemoglobin value?');
        final other = model.inputs.last;
        expect(other['currentSessionUserContext'], isNull);
        expect(other['userStatedConversationMemories'], isEmpty);
        expect(jsonEncode(other), isNot(contains('hemoglobal was 13')));
        expect(jsonEncode(other), isNot(contains('ASSISTANT_ONLY_7777')));
        expect(controller.messages.last.text, contains('[report-b/p1-l1]'));

        await controller.selectProfile(ownerA);
        await controller.deleteConversation(sessionId);
        expect(
          controller.data.memories.where((m) => m.profileId == ownerA),
          isEmpty,
        );
        await controller.ask('What is my latest hemoglobin value?');
        final deleted = model.inputs.last;
        expect(deleted['currentSessionUserContext'], isNull);
        expect(deleted['userStatedConversationMemories'], isEmpty);
        expect(jsonEncode(deleted), isNot(contains('hemoglobal was 13')));
        expect(controller.messages.last.text, contains('[report-a/p1-l1]'));
        expect(controller.reports.single.facts.single.value, '11.2');
        expect(controller.failure, isNull);
      },
    );
    test(
      '${browser ? 'browser' : 'native'} user statement forces local corroboration even with a conversation plan',
      () async {
        final model = _ContextModel()..conversationPlan = true;
        final controller = await _ready(browser, model);
        controller.data = controller.data.copy(
          reports: [_report('report-13', controller.profile!.id, '13')],
        );
        await controller.ask('hemoglobin was 13 on 2026-03-14');
        final input = model.inputs.single;
        final context = input['currentSessionUserContext'] as Map;
        expect(context['text'], contains('on 2026-03-14'));
        expect(context['clinicalDateStatus'], contains('explicitly stated'));
        expect(
          controller.messages.last.text,
          contains('[conversation:${controller.activeSession!.id}]'),
        );
        expect(
          controller.messages.last.text,
          contains('report corroborates 13 [report-13/p1-l1]'),
        );
        expect(
          controller.messages.last.hits.single.citation,
          'report-13/p1-l1',
        );
        expect(controller.reports.single.facts.single.corrected, false);
        await controller.newConversation();
        await controller.ask('hemoglobin was 13 on 2026-03-16');
        expect(controller.messages.last.text, contains('Do you have a report'));
        expect(controller.messages.last.hits, isEmpty);
        expect(
          ((model.inputs.last['evidence'] as List).single as Map)['eventDate'],
          DateTime.utc(2026, 3, 14).toIso8601String(),
        );
        expect(controller.failure, isNull);
      },
    );
    test(
      '${browser ? 'browser' : 'native'} mixed update plus question keeps the declarative clause only',
      () async {
        final model = _ContextModel();
        final controller = await _ready(browser, model);
        await controller.ask(
          'hemoglobin was 13.5 on 2026-03-14. What does that mean?',
        );
        expect(model.inputs, hasLength(1));
        final context = model.inputs.single['currentSessionUserContext'] as Map;
        expect(context['text'], contains('hemoglobin was 13.5 on 2026-03-14'));
        expect(context['text'], isNot(contains('What does that mean')));
        expect((context['currentTurn'] as Map)['kind'], 'user_statement');
        expect(
          (context['userTurns'] as List).cast<Map>().single['providedAt'],
          controller.activeSession!.turns.first.createdAt.toIso8601String(),
        );
        expect(
          controller.messages.last.text,
          contains('[conversation:${controller.activeSession!.id}]'),
        );
        expect(controller.messages.last.text, contains('Do you have a report'));
        expect(controller.failure, isNull);
      },
    );
    test(
      '${browser ? 'browser' : 'native'} please-remember unwraps to the remembered observation',
      () async {
        final model = _ContextModel();
        final controller = await _ready(browser, model);
        await controller.ask('Please remember my hemoglobin was 13');
        expect(model.inputs, hasLength(1));
        final context = model.inputs.single['currentSessionUserContext'] as Map;
        expect(context['text'], contains('my hemoglobin was 13'));
        expect(context['text'], isNot(contains('Please remember')));
        expect((context['currentTurn'] as Map)['kind'], 'user_statement');
        expect(
          controller.messages.last.text,
          contains('[conversation:${controller.activeSession!.id}]'),
        );
        expect(controller.failure, isNull);
      },
    );
    test(
      '${browser ? 'browser' : 'native'} hypothetical questions never become findings',
      () async {
        final model = _ContextModel();
        final controller = await _ready(browser, model);
        await controller.ask('hemoglobin was 13');
        await controller.ask('What if my hemoglobin is 13?');
        final context = model.inputs.last['currentSessionUserContext'] as Map;
        expect(context['text'], contains('hemoglobin was 13'));
        expect(context['text'], isNot(contains('What if')));
        expect((context['currentTurn'] as Map)['kind'], 'request');
        expect(controller.failure, isNull);
      },
    );
  }
}
