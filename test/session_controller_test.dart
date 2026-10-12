import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class SessionIntelligence extends LocalIntelligence {
  final plannerInputs = <Map<String, dynamic>>[];
  final answerInputs = <Map<String, dynamic>>[];

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    final payload = Map<String, dynamic>.from(jsonDecode(input) as Map);
    if (instruction == plannerPrompt) {
      plannerInputs.add(payload);
      return '{"actions":[{"action":"conversation","query":""}]}';
    }
    answerInputs.add(payload);
    return 'ASSISTANT_ONLY_MARKER';
  }
}

void main() {
  late Directory directory;
  late EncryptedVault vault;
  late SessionIntelligence intelligence;
  late AppController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ayumitra-sessions-');
    vault = EncryptedVault(
      directory: directory,
      key: await AesGcm.with256bits().newSecretKey(),
    );
    intelligence = SessionIntelligence();
    controller = AppController(intelligence: intelligence)
      ..vault = vault
      ..loaded = true;
  });

  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'DOB profiles save, edit, and reject a future DOB without data loss',
    () async {
      await controller.createProfile(
        'Synthetic Child',
        DateTime(2020, 5, 12),
        'User-provided history',
        true,
      );
      final childId = controller.profile!.id;
      await controller.createProfile(
        'Synthetic Adult',
        DateTime(1990, 2, 3),
        '',
        false,
      );
      final adultId = controller.profile!.id;
      expect(controller.data.profiles, hasLength(2));
      expect(controller.profile!.isChild, isFalse);

      controller.data = controller.data.copy(
        reports: [
          for (final id in [childId, adultId])
            Report(
              id: id == childId ? 'child-report' : 'adult-report',
              profileId: id,
              name: 'Synthetic age summary',
              extension: 'txt',
              digest: 'synthetic',
              importedAt: DateTime(2026),
              summaryMarkdown: 'An existing summary with age information',
            ),
        ],
      );
      await vault.save(controller.data);

      await controller.selectProfile(childId);
      expect(controller.profile!.dateOfBirth, DateTime(2020, 5, 12));
      await controller.updateProfile(
        childId,
        name: 'Synthetic Child Updated',
        dateOfBirth: DateTime(2020, 5, 13),
        history: 'Corrected user history',
        isChild: true,
      );
      expect(controller.profile!.history, 'Corrected user history');
      expect(controller.profile!.dateOfBirth, DateTime(2020, 5, 13));
      expect(controller.reports.single.summaryMarkdown, isNull);
      expect(
        controller.data.reports
            .firstWhere((r) => r.profileId == adultId)
            .summaryMarkdown,
        'An existing summary with age information',
      );
      await controller.updateProfile(
        childId,
        name: 'Invalid edit',
        dateOfBirth: DateTime(2999),
        history: 'Must not replace history',
        isChild: true,
      );
      expect(controller.failure, isNotNull);
      final saved = await vault.read();
      expect(saved.activeProfileId, childId);
      expect(
        saved.profiles.firstWhere((p) => p.id == childId).name,
        'Synthetic Child Updated',
      );
      expect(
        saved.profiles.firstWhere((p) => p.id == adultId).dateOfBirth,
        DateTime(1990, 2, 3),
      );
    },
  );

  test(
    'Older conversation choices survive profile switching and vault reload',
    () async {
      await controller.createProfile('Synthetic A', DateTime(2000), '', false);
      final a = controller.profile!.id;
      await controller.ask('An older conversation for profile A');
      final older = controller.activeSession!.id;
      await controller.newConversation();
      await controller.ask('The latest conversation for profile A');
      final latest = controller.activeSession!.id;
      await controller.selectConversation(older);

      await controller.createProfile('Synthetic B', DateTime(2010), '', true);
      final b = controller.profile!.id;
      await controller.ask('The selected conversation for profile B');
      final bSession = controller.activeSession!.id;
      await controller.selectProfile(a);
      expect(controller.activeSessionId, older);
      expect(controller.activeSessionId, isNot(latest));
      expect(
        controller.messages.first.text,
        'An older conversation for profile A',
      );
      await controller.selectProfile(b);
      expect(controller.activeSessionId, bSession);

      controller.data = await vault.read();
      await controller.selectProfile(a);
      expect(controller.activeSessionId, older);
      final saved = await vault.read();
      expect(saved.activeSessionByProfile[a], older);
      expect(saved.activeSessionByProfile[b], bSession);
    },
  );

  test(
    'New conversations preserve earlier turns and restore from encrypted storage',
    () async {
      await controller.createProfile('Synthetic', DateTime(2000), '', false);
      await controller.ask('Remember SYNTHETIC_RESTART_MARKER');
      final firstId = controller.activeSession!.id;
      expect(controller.activeSession!.turns.map((t) => t.role), [
        'user',
        'assistant',
      ]);
      expect(
        controller.activeSession!.title,
        'Remember SYNTHETIC_RESTART_MARKER',
      );

      await controller.newConversation();
      final secondId = controller.activeSession!.id;
      expect(secondId, isNot(firstId));
      expect(controller.messages, isEmpty);
      await controller.ask('A second synthetic conversation');
      await controller.selectConversation(firstId);
      expect(
        controller.messages.first.text,
        'Remember SYNTHETIC_RESTART_MARKER',
      );

      final encrypted = await File('${directory.path}/index.enc').readAsBytes();
      expect(
        utf8.decode(encrypted, allowMalformed: true),
        isNot(contains('SYNTHETIC_RESTART_MARKER')),
      );
      final reopenedVault = EncryptedVault(
        directory: directory,
        key: vault.key,
      );
      final reopened = AppController(intelligence: SessionIntelligence())
        ..vault = reopenedVault
        ..data = await reopenedVault.read()
        ..loaded = true;
      try {
        reopened.activeProfileId = reopened.data.activeProfileId;
        reopened.activeSessionId = reopened.data.activeSessionId;
        reopened.restoreConversation();
        expect(reopened.sessions, hasLength(2));
        expect(reopened.activeSessionId, firstId);
        expect(reopened.messages.map((m) => m.text), [
          'Remember SYNTHETIC_RESTART_MARKER',
          'ASSISTANT_ONLY_MARKER',
        ]);
        await reopened.selectConversation(secondId);
        expect(reopened.messages.first.text, 'A second synthetic conversation');
      } finally {
        reopened.dispose();
      }
    },
  );

  test(
    'Session selection and deletion cannot cross profile ownership',
    () async {
      await controller.createProfile('Synthetic A', DateTime(2000), '', false);
      final a = controller.profile!.id;
      await controller.ask('A private synthetic conversation');
      final aSession = controller.activeSession!.id;
      await controller.createProfile('Synthetic B', DateTime(2010), '', true);
      final b = controller.profile!.id;
      await controller.ask('B private synthetic conversation');
      final bSession = controller.activeSession!.id;

      await controller.selectProfile(a);
      expect(controller.sessions.map((s) => s.id), [aSession]);
      await controller.selectConversation(bSession);
      expect(controller.activeSessionId, aSession);
      await controller.deleteConversation(bSession);
      expect(controller.data.sessions.any((s) => s.id == bSession), isTrue);
      expect(
        controller.messages.first.text,
        'A private synthetic conversation',
      );

      await controller.selectProfile(b);
      expect(controller.sessions.map((s) => s.id), [bSession]);
      expect(
        controller.messages.first.text,
        'B private synthetic conversation',
      );
      expect((await vault.read()).activeProfileId, b);
    },
  );

  test(
    'Recall uses same-profile user context, excluding assistant turns and planner tools',
    () async {
      await controller.createProfile('Synthetic A', DateTime(2000), '', false);
      final a = controller.profile!.id;
      await controller.ask('Remember orchid A_ONLY_CONTEXT');
      final first = controller.activeSession!.id;
      expect(controller.data.memories.single.text, contains('A_ONLY_CONTEXT'));
      expect(
        controller.data.memories.single.text,
        isNot(contains('ASSISTANT_ONLY_MARKER')),
      );
      await controller.createProfile('Synthetic B', DateTime(2010), '', true);
      await controller.ask('Remember orchid B_ONLY_CONTEXT');
      await controller.selectProfile(a);
      await controller.newConversation();
      await controller.ask('Recall orchid');

      final answer = intelligence.answerInputs.last;
      expect(
        jsonEncode(answer['userStatedContext']),
        contains('A_ONLY_CONTEXT'),
      );
      expect(jsonEncode(answer), isNot(contains('B_ONLY_CONTEXT')));
      expect(jsonEncode(answer), isNot(contains('ASSISTANT_ONLY_MARKER')));
      expect(
        jsonEncode(intelligence.plannerInputs.last),
        isNot(contains('A_ONLY_CONTEXT')),
      );
      expect(intelligence.plannerInputs.last['recentUserRequests'], isEmpty);
      expect(
        controller.data.memories.firstWhere((m) => m.sessionId == first).text,
        contains('Unverified; not medical evidence'),
      );
    },
  );

  test(
    'Deleting a session removes its recall but retains reports and other profiles',
    () async {
      await controller.createProfile('Synthetic A', DateTime(2000), '', false);
      final a = controller.profile!.id;
      await controller.ask('Remember orchid DELETE_MEMORY_MARKER');
      final deleted = controller.activeSession!.id;
      final report = Report(
        id: 'synthetic-report',
        profileId: a,
        name: 'Synthetic report.txt',
        extension: 'txt',
        digest: 'synthetic',
        importedAt: DateTime(2026),
      );
      final original = Uint8List.fromList(utf8.encode('SYNTHETIC ORIGINAL'));
      await vault.saveOriginal(report, original);
      controller.data = controller.data.copy(reports: [report]);
      await vault.save(controller.data);
      await controller.createProfile('Synthetic B', DateTime(2010), '', true);
      await controller.ask('Remember orchid B_RETAINED_CONTEXT');
      final retained = controller.activeSession!.id;

      await controller.selectProfile(a);
      await controller.deleteConversation(deleted);
      expect(controller.activeSession, isNull);
      expect(controller.messages, isEmpty);
      final saved = await vault.read();
      expect(saved.sessions.any((s) => s.id == deleted), isFalse);
      expect(saved.memories.any((m) => m.sessionId == deleted), isFalse);
      expect(saved.sessions.any((s) => s.id == retained), isTrue);
      expect(saved.memories.any((m) => m.sessionId == retained), isTrue);
      expect(saved.reports.single.id, report.id);
      expect(await controller.original(report), original);

      await controller.newConversation();
      await controller.ask('Recall orchid');
      expect(
        jsonEncode(intelligence.answerInputs.last),
        isNot(contains('DELETE_MEMORY_MARKER')),
      );
      expect(
        jsonEncode(intelligence.answerInputs.last),
        isNot(contains('B_RETAINED_CONTEXT')),
      );
    },
  );
}
