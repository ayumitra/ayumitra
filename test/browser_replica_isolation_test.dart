import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/retrieval.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:flutter_test/flutter_test.dart';

import '../checks/preview_workflow_test.dart'
    show FakeEmbeddings, FakeIntelligence;

Uint8List _bytes() =>
    Uint8List.fromList(utf8.encode('Hb 11.2 g/dL [12.0-16.0]\n'));

FakeIntelligence _model() => FakeIntelligence()
  ..organizerResponse = '{"type":"lab","eventDate":null,"dateEvidence":null}'
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

Future<DemoController> _ready({FakeIntelligence? intelligence}) async {
  final controller = DemoController(
    intelligence: intelligence ?? _model(),
    embeddings: FakeEmbeddings(),
  );
  await controller.initialize();
  await controller.createProfile('Synthetic A', DateTime(2020, 1, 1), '', true);
  return controller;
}

class _UnavailableModel extends FakeIntelligence {
  _UnavailableModel(this.beforeFailure);
  final void Function() beforeFailure;
  @override
  Future<String> generate(String instruction, String input) async {
    beforeFailure();
    throw StateError('Synthetic localhost model unavailable');
  }
}

class _BlockedModel extends FakeIntelligence {
  final started = Completer<void>();
  final released = Completer<void>();
  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == organizerPrompt && !released.isCompleted) {
      if (!started.isCompleted) started.complete();
      await released.future;
    }
    return super.generate(instruction, input);
  }
}

void main() {
  test(
    'deleting a colliding session ID preserves the other profile’s turns, memory and selection',
    () async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      final profileA = controller.profile!.id;
      await controller.createProfile(
        'Synthetic B',
        DateTime(1990, 1, 1),
        '',
        false,
      );
      final profileB = controller.profile!.id;
      final now = DateTime.utc(2026, 10, 13);
      const sharedId = 'synthetic-colliding-session';
      ConversationSession session(String profile, String marker) =>
          ConversationSession(
            id: sharedId,
            profileId: profile,
            title: marker,
            createdAt: now,
            updatedAt: now,
            turns: [
              ConversationTurn(
                id: '$profile-user',
                role: 'user',
                text: marker,
                createdAt: now,
              ),
            ],
          );
      final a = session(profileA, 'A_PRIVATE_CONTEXT');
      final b = session(profileB, 'B_PRIVATE_CONTEXT');
      final memoryB = buildConversationMemory(b);
      controller.data = controller.data.copy(
        sessions: [a, b],
        memories: [buildConversationMemory(a), memoryB],
        activeSessionByProfile: {profileA: sharedId, profileB: sharedId},
      );
      await controller.selectProfile(profileA);
      expect(controller.messages.single.text, 'A_PRIVATE_CONTEXT');
      await controller.deleteConversation(sharedId);
      expect(controller.data.sessions.length, 1);
      expect(controller.data.sessions.single.toJson(), b.toJson());
      expect(controller.data.memories.single.toJson(), memoryB.toJson());
      expect(controller.data.activeSessionByProfile[profileB], sharedId);
      expect(
        controller.data.activeSessionByProfile.containsKey(profileA),
        false,
      );
      expect(controller.activeSessionId, isNull);
      expect(controller.messages, isEmpty);
      await controller.selectProfile(profileB);
      expect(controller.activeSessionId, sharedId);
      expect(controller.messages.single.text, 'B_PRIVATE_CONTEXT');
    },
  );

  test(
    'identical file imports belong to distinct profiles; retry and correction stay scoped',
    () async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      final profileA = controller.profile!.id;
      await controller.importBytes('same.txt', 'txt', _bytes());
      final reportA = controller.reports.single;
      final snapshotA = reportA.toJson();
      await controller.createProfile(
        'Synthetic B',
        DateTime(1990, 1, 1),
        '',
        false,
      );
      final profileB = controller.profile!.id;
      await controller.importBytes('same.txt', 'txt', _bytes());
      final reportB = controller.reports.single;
      expect(reportB.id, isNot(reportA.id));
      expect(controller.data.reports.length, 2);
      expect(
        controller.data.reports
            .singleWhere((report) => report.profileId == profileA)
            .toJson(),
        snapshotA,
      );
      await controller.correctFact(reportB, reportB.facts.single, '11.9');
      await controller.retry(controller.reports.single);
      expect(controller.reports.single.facts.single.value, '11.9');
      expect(
        controller.data.reports
            .singleWhere((report) => report.profileId == profileA)
            .toJson(),
        snapshotA,
      );
      expect(controller.reports.single.profileId, profileB);
      await expectLater(controller.original(reportA), throwsStateError);
      final snapshotB = controller.reports.single.toJson();
      await controller.retry(reportA);
      await controller.correctFact(reportA, reportA.facts.single, '99');
      expect(controller.reports.single.toJson(), snapshotB);
      await controller.selectProfile(profileA);
      expect(controller.reports.single.toJson(), snapshotA);
      expect(await controller.original(controller.reports.single), _bytes());
    },
  );

  test(
    'forged source ownership and stale retry cannot expose or replace another profile',
    () async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      await controller.importBytes('original.txt', 'txt', _bytes());
      final original = controller.reports.single;
      await controller.correctFact(original, original.facts.single, '11.9');
      await controller.retry(
        original,
      ); // Stale object must resolve saved corrections.
      expect(controller.reports.single.facts.single.value, '11.9');
      final ownedSnapshot = controller.reports.single.toJson();
      await controller.createProfile('Synthetic B', DateTime(1990), '', false);
      final forged = Report(
        id: original.id,
        profileId: controller.profile!.id,
        name: 'forged.txt',
        extension: 'txt',
        digest: original.digest,
        importedAt: original.importedAt,
      );
      await expectLater(controller.original(forged), throwsStateError);
      await controller.retry(forged);
      expect(controller.reports, isEmpty);
      expect(controller.data.reports.single.toJson(), ownedSnapshot);
    },
  );

  test('unreadable page markers cannot consume retrieved evidence slots', () {
    final report = Report(
      id: 'r',
      profileId: 'p',
      name: 'synthetic.pdf',
      extension: 'pdf',
      digest: 'x',
      importedAt: DateTime(2026),
      lines: const [
        SourceLine(id: 'blank', page: 1, text: '', method: 'text-sparse'),
        SourceLine(id: 'spaces', page: 2, text: '  ', method: 'text-sparse'),
        SourceLine(
          id: 'readable',
          page: 3,
          text: 'Synthetic hemoglobin source',
        ),
      ],
    );
    final hits = retrieve(
      profileId: 'p',
      reports: [report],
      query: 'summarize my history',
      limit: 1,
    );
    expect(hits.single.line.id, 'readable');
    expect(
      report.lines,
      hasLength(3),
    ); // Review markers remain part of the original report.
  });

  test(
    'assistant completion retains the semantic vector for user-only memory',
    () async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      await controller.ask('Remember a synthetic pollen allergy discussion.');
      final memory = controller.data.memories.single;
      expect(memory.vector, isNotNull);
      expect(memory.embeddingVersion, 'fake:1');
      expect(memory.text, contains('pollen allergy'));
      expect(memory.text, isNot(contains('Local answer')));
      expect(controller.activeSession!.turns.map((turn) => turn.role), [
        'user',
        'assistant',
      ]);
    },
  );

  test(
    'model failure keeps the complete user turn and memory, resets activity, and explains failure',
    () async {
      late DemoController controller;
      final request =
          'SYNTHETIC_USER_START ${'user text ' * 600} SYNTHETIC_USER_END';
      final model = _UnavailableModel(() {
        expect(controller.activeSession!.turns.single.text, request);
        expect(
          controller.data.memories.single.text,
          contains('SYNTHETIC_USER_START'),
        );
      });
      controller = await _ready(intelligence: model);
      addTearDown(controller.dispose);
      await controller.ask(request);
      expect(
        controller.activeSession!.turns
            .where((turn) => turn.role == 'user')
            .single
            .text,
        request,
      );
      expect(
        controller.messages.any(
          (message) => message.isUser && message.text == request,
        ),
        true,
      );
      expect(
        controller.data.memories.single.text,
        contains('SYNTHETIC_USER_START'),
      );
      expect(controller.failure, isNotNull);
      expect(controller.failure!.trim(), isNotEmpty);
      expect(controller.busy, false);
      expect(controller.activity, '');
    },
  );

  test(
    'unconfigured text imports and keyword search require no platform or model',
    () async {
      final controller = DemoController();
      await controller.initialize();
      addTearDown(controller.dispose);
      await controller.createProfile(
        'Synthetic A',
        DateTime(2020, 1, 1),
        '',
        true,
      );
      await controller.importBytes('same.txt', 'txt', _bytes());
      expect(
        controller.reports.single.lines.single.text,
        'Hb 11.2 g/dL [12.0-16.0]',
      );
      await controller.ask('Hb');
      expect(controller.messages.last.hits.length, 1);
      expect(controller.busy, false);
    },
  );

  test(
    'public byte import refuses missing profile, invalid type and oversized data',
    () async {
      final empty = DemoController();
      await empty.initialize();
      addTearDown(empty.dispose);
      await empty.importBytes('same.txt', 'txt', _bytes());
      expect(empty.data.reports, isEmpty);
      final controller = await _ready();
      addTearDown(controller.dispose);
      await controller.importBytes('invalid.exe', 'exe', _bytes());
      expect(controller.reports, isEmpty);
      await controller.importBytes(
        'huge.txt',
        'txt',
        Uint8List(30 * 1024 * 1024 + 1),
      );
      expect(controller.reports, isEmpty);
      expect(controller.failure, contains('30 MB'));
      expect(controller.busy, false);
      expect(controller.activity, '');
    },
  );

  test('public byte imports do not process concurrently', () async {
    final model = _BlockedModel();
    final controller = await _ready(intelligence: model);
    addTearDown(controller.dispose);
    final first = controller.importBytes('first.txt', 'txt', _bytes());
    await model.started.future;
    expect(controller.busy, true);
    final secondBytes = Uint8List.fromList(
      utf8.encode('Synthetic other note\n'),
    );
    await controller.importBytes('second.txt', 'txt', secondBytes);
    expect(controller.data.reports.length, 1);
    expect(controller.data.reports.single.name, 'first.txt');
    model.released.complete();
    await first;
    expect(controller.busy, false);
    await controller.importBytes('second.txt', 'txt', secondBytes);
    expect(controller.data.reports.length, 2);
    expect(controller.busy, false);
  });
}
