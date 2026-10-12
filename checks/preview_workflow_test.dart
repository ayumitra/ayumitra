// In-memory replica workflow tests (no sample data, no network).
// A fake localhost model answers through the real prompts/validators, so
// these tests cover the actual import → extract → retrieve → answer flow.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_research.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted stand-in for the user's localhost server. Routes on the real
/// prompt constants; citations are echoed from the model input.
class FakeIntelligence extends LocalIntelligence {
  String plannerResponse = '{"action":"conversation","query":""}';
  String organizerResponse = '{}';
  String extractorResponse = '{"facts":[]}';
  String Function(Map input)? summaryFn;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == plannerPrompt) return plannerResponse;
    if (instruction == organizerPrompt) return organizerResponse;
    if (instruction == extractorPrompt) return extractorResponse;
    if (instruction == researchPlannerPrompt) {
      return '{"actions":[{"action":"finish"}]}';
    }
    if (instruction == researchAssessorPrompt) {
      return '{"missingTopics":[]}';
    }
    final decoded = jsonDecode(input) as Map;
    if (summaryFn != null) return summaryFn!(decoded);
    final ids = RegExp(
      r'"sourceId":"([^"]+)"',
    ).allMatches(input).map((m) => m.group(1)).toSet().take(2).toList();
    return 'Local answer ${ids.map((id) => '[$id]').join(' ')}.';
  }
}

class FakeEmbeddings extends LocalEmbeddings {
  @override
  bool get available => true;

  @override
  Future<void> load(String path, String fingerprint) async {
    version = 'fake:1';
  }

  @override
  Future<List<double>> embed(String text, {bool document = false}) async {
    version ??= 'fake:1';
    final hash = text.length % 7;
    return [1.0 + hash, 0.5, 0.25];
  }
}

Uint8List _reportBytes() => Uint8List.fromList(
  utf8.encode(
    'Hb 11.2 g/dL [12.0-16.0]\nReport date: 2026-03-14\nWBC 7.4 10^9/L [4.0-12.0]\n',
  ),
);

DemoController _controller(FakeIntelligence intelligence) =>
    DemoController(intelligence: intelligence, embeddings: FakeEmbeddings());

Future<DemoController> _ready({String? history}) async {
  final intelligence = FakeIntelligence()
    ..organizerResponse = jsonEncode({
      'type': 'lab',
      'eventDate': '2026-03-14',
      'dateEvidence': 'Report date: 2026-03-14',
      'dateSourceLineId': 'p1-l2',
    })
    ..extractorResponse = jsonEncode({
      'facts': [
        {
          'kind': 'lab',
          'name': 'Hb',
          'value': '11.2',
          'unit': 'g/dL',
          'range': '12.0-16.0',
          'sourceLineId': 'p1-l1',
          'evidence': 'Hb 11.2 g/dL [12.0-16.0]',
        },
      ],
    });
  final controller = _controller(intelligence);
  await controller.initialize();
  await controller.createProfile(
    'Test Child',
    DateTime(2021, 4, 18),
    history ?? '',
    true,
  );
  return controller;
}

void main() {
  test(
    'in-memory replica imports, extracts, and answers from own documents',
    () async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      await controller.importBytes('blood.txt', 'txt', _reportBytes());
      expect(controller.reports, hasLength(1));
      final report = controller.reports.single;
      // No bundled sample data: only what was imported exists.
      expect(report.name, 'blood.txt');
      expect(report.type, 'lab');
      final event = report.eventDate!;
      expect((event.year, event.month, event.day), (2026, 3, 14));
      expect(report.facts.single.value, '11.2');
      expect(report.summaryMarkdown, contains('[${report.id}/p1-l1]'));

      (controller.intelligence as FakeIntelligence).plannerResponse =
          '{"actions":[{"action":"search_records","query":"hb value"}]}';
      await controller.ask('What is my Hb?');
      final answer = controller.messages.last;
      expect(answer.isUser, isFalse);
      expect(answer.text, contains('[${report.id}/p1-l1]'));
      expect(answer.hits, isNotEmpty);
      expect(
        answer.hits.map((h) => h.line.text),
        contains('Hb 11.2 g/dL [12.0-16.0]'),
      );
      expect(
        answer.hits.every((h) => h.report.profileId == controller.profile!.id),
        isTrue,
      );
      // Transcript persisted to the session with user + assistant turns.
      expect(
        controller.activeSession!.turns.map((t) => t.role),
        containsAll(['user', 'assistant']),
      );
      expect(controller.data.memories, isNotEmpty);
    },
  );

  test(
    'correction clears the summary, survives retry, original untouched',
    () async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      await controller.importBytes('blood.txt', 'txt', _reportBytes());
      final report = controller.reports.single;
      final original = await controller.original(report);
      await controller.correctFact(report, report.facts.single, '11.9');
      final changed = controller.reports.single;
      expect(changed.summaryMarkdown, isNull);
      expect(changed.facts.single.corrected, isTrue);
      expect(changed.facts.single.originalValue, '11.2');
      await controller.retry(changed);
      final reprocessed = controller.reports.single;
      expect(reprocessed.facts.single.value, '11.9');
      expect(reprocessed.facts.single.corrected, isTrue);
      expect(await controller.original(reprocessed), original);
    },
  );

  test('no model connected degrades to keyword excerpts', () async {
    final controller = DemoController();
    await controller.initialize();
    addTearDown(controller.dispose);
    await controller.createProfile(
      'Test Child',
      DateTime(2021, 4, 18),
      '',
      true,
    );
    expect(controller.intelligence.available, isFalse);
    await controller.ask('Hello?');
    expect(
      controller.messages.last.text,
      contains('local chat model in settings'),
    );
    // A session still exists for the turns, in memory only.
    expect(controller.activeSession, isNotNull);
  });

  test(
    'sessions isolate profiles; deletion removes memory, keeps reports',
    () async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      await controller.importBytes('blood.txt', 'txt', _reportBytes());
      await controller.ask('What is my Hb?');
      final firstId = controller.activeSessionId!;
      await controller.newConversation();
      await controller.ask('And the WBC?');
      final secondId = controller.activeSessionId!;
      await controller.createProfile('Second', DateTime(1990, 2, 3), '', false);
      expect(controller.reports, isEmpty);
      expect(controller.messages, isEmpty);
      await controller.selectProfile(
        controller.data.profiles.firstWhere((p) => p.name == 'Test Child').id,
      );
      await controller.deleteConversation(secondId);
      expect(controller.data.sessions.any((s) => s.id == secondId), isFalse);
      expect(
        controller.data.memories.any((m) => m.sessionId == secondId),
        isFalse,
      );
      expect(controller.reports, hasLength(1));
      expect(controller.data.sessions.any((s) => s.id == firstId), isTrue);
    },
  );

  test('autonomous extended thinking is labeled from local research', () async {
    final controller = await _ready(history: 'User-provided background.');
    addTearDown(controller.dispose);
    await controller.importBytes('blood.txt', 'txt', _reportBytes());
    final intelligence = controller.intelligence as FakeIntelligence;
    intelligence.plannerResponse =
        '{"actions":[{"action":"extended_thinking","query":""},{"action":"search_records","query":"hb"}]}';
    intelligence.summaryFn = (input) => 'Background note [user-history].';
    await controller.ask('Research my hemoglobin thoroughly');
    final answer = controller.messages.last;
    expect(answer.text.startsWith('**Extended thinking**'), isTrue);
    expect(answer.text, contains('[user-history]'));
  });

  test('reload clears the in-memory vault by design', () async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    await controller.importBytes('blood.txt', 'txt', _reportBytes());
    expect(controller.reports, hasLength(1));
    await controller.initialize();
    expect(controller.data.reports, isEmpty);
    expect(controller.messages, isEmpty);
  });
}
