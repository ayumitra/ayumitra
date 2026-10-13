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
    if (instruction.startsWith(summaryPrompt) ||
        instruction.startsWith(userObservationPrompt)) {
      final current = payload['currentSessionUserContext'] as Map?;
      final recalled = payload['userStatedConversationMemories'] as List;
      final source =
          current?['sourceId'] ?? (recalled.first as Map)['sourceId'];
      return 'ASSISTANT_ONLY_MARKER [$source]';
    }
    return 'ASSISTANT_ONLY_MARKER';
  }
}

/// Mutable-plan fake for the MSG-048 recall regression: records both the
/// conversation-path and summary-path model inputs for inspection.
class RecallIntelligence extends LocalIntelligence {
  final answerInputs = <Map<String, dynamic>>[];
  String plan = '{"action":"conversation","query":""}';

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    final payload = Map<String, dynamic>.from(jsonDecode(input) as Map);
    if (instruction == plannerPrompt) return plan;
    answerInputs.add(payload);
    final current = payload['currentSessionUserContext'] as Map?;
    final recalled = payload['userStatedConversationMemories'] as List? ?? [];
    final source = current?['sourceId'] ?? (recalled.first as Map)['sourceId'];
    return 'SYNTHETIC ANSWER [$source]';
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
    'profile background persists as a user turn before the first model call',
    () async {
      const background =
          'Synthetic background: penicillin allergy noted by caregiver.';
      await controller.createProfile(
        'Synthetic A',
        DateTime(2020),
        background,
        true,
      );
      final owner = controller.profile!.id;
      final seededId = controller.activeSessionId!;
      expect(intelligence.plannerInputs, isEmpty);
      expect(intelligence.answerInputs, isEmpty);
      expect(controller.messages.single.isUser, isTrue);
      final saved = await vault.read();
      expect(saved.activeSessionByProfile[owner], seededId);
      expect(saved.sessions.single.turns.single.role, 'user');
      expect(saved.sessions.single.turns.single.text, contains(background));
      expect(saved.memories.single.profileId, owner);
      expect(saved.memories.single.sessionId, seededId);
      expect(saved.memories.single.text, contains(background));

      await controller.ask('Hello, what can you help me with?');
      expect(
        (intelligence.plannerInputs.single['recentUserRequests'] as List)
            .join(),
        contains(background),
      );
      expect(
        controller.activeSession!.title,
        'Hello, what can you help me with?',
      );
      expect(controller.activeSession!.turns, hasLength(3));
      expect(
        controller.data.memories.single.text,
        isNot(contains('ASSISTANT_ONLY_MARKER')),
      );

      await controller.createProfile('Synthetic B', DateTime(1990), '', false);
      expect(controller.activeSessionId, isNull);
      expect(controller.messages, isEmpty);
      await controller.ask('Hello from profile B');
      expect(
        jsonEncode(intelligence.plannerInputs.last),
        isNot(contains(background)),
      );
      expect(
        jsonEncode(intelligence.answerInputs.last),
        isNot(contains(background)),
      );
      await controller.selectProfile(owner);
      expect(controller.activeSessionId, seededId);
      expect(controller.messages.first.text, contains(background));
      await controller.deleteConversation(seededId);
      expect(controller.sessions, isEmpty);
      expect(
        controller.data.memories.where((m) => m.profileId == owner),
        isEmpty,
      );
      // Deleting conversation memory does not erase the separate profile field.
      expect(controller.profile!.history, background);
      final afterDelete = await vault.read();
      expect(afterDelete.sessions.where((s) => s.profileId == owner), isEmpty);
      expect(afterDelete.memories.where((m) => m.profileId == owner), isEmpty);
    },
  );

  test(
    'empty profile background creates no initial session or memory',
    () async {
      await controller.createProfile(
        'Synthetic empty',
        DateTime(2000),
        '  ',
        false,
      );
      final saved = await vault.read();
      expect(saved.sessions, isEmpty);
      expect(saved.memories, isEmpty);
      expect(controller.messages, isEmpty);
      expect(controller.activeSessionId, isNull);
    },
  );

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
          'ASSISTANT_ONLY_MARKER [conversation:$firstId]',
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
        jsonEncode(answer['userStatedConversationMemories']),
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
      final callsBeforeRecall = intelligence.answerInputs.length;
      await controller.ask('Recall orchid');
      expect(intelligence.answerInputs.length, callsBeforeRecall);
      expect(
        controller.messages.last.text,
        isNot(contains('DELETE_MEMORY_MARKER')),
      );
      expect(
        controller.messages.last.text,
        isNot(contains('B_RETAINED_CONTEXT')),
      );
    },
  );

  test(
    'Long memory recall surfaces the later matching statement in both paths',
    () async {
      // MSG-048: the stored memory runs far past the old first-1500 window,
      // so only query-relevant selection keeps the later match in model input.
      final recall = RecallIntelligence();
      final local = AppController(intelligence: recall)
        ..vault = vault
        ..loaded = true;
      try {
        await local.createProfile('Synthetic A', DateTime(2000), '', false);
        final a = local.profile!.id;
        await local.ask('Synthetic filler one ${'irrelevant ' * 100}');
        await local.ask('Synthetic filler two ${'unrelated ' * 100}');
        await local.ask(
          'Note for later: zephyrin 250mg SYNTHETIC_LATER_MARKER end',
        );
        final originId = local.activeSessionId!;
        final stored = local.data.memories.single.text;
        expect(stored.indexOf('SYNTHETIC_LATER_MARKER') > 1500, isTrue);

        // A non-greeting conversation classification now takes the grounded
        // answer path, with the same recalled source as a record-search plan.
        await local.newConversation();
        await local.ask('What did I note about zephyrin?');
        final convoInput = recall.answerInputs.last;
        final recalled = convoInput['userStatedConversationMemories'] as List;
        final context = recalled.map((row) => (row as Map)['text']).join('\n');
        expect(context, contains('SYNTHETIC_LATER_MARKER'));
        expect(context, contains('User turn '));
        expect(context, contains('user-stated'));
        expect(context, isNot(contains('SYNTHETIC ANSWER')));
        for (final entry in recalled) {
          expect(
            ((entry as Map)['text'] as String).length,
            lessThanOrEqualTo(1000),
          );
        }
        expect(local.messages.last.text, contains('[conversation:$originId]'));

        // Summary path with the same recall.
        recall.plan = '{"action":"search_records","query":"zephyrin note"}';
        await local.ask('Summarize my zephyrin note');
        final summaryInput = recall.answerInputs.last;
        final mems = summaryInput['userStatedConversationMemories'] as List;
        expect(mems, hasLength(1));
        final mem = mems.single as Map;
        expect(mem['sourceId'], 'S1');
        expect(
          jsonEncode(summaryInput),
          isNot(contains('conversation:$originId')),
        );
        expect(mem['text'] as String, contains('SYNTHETIC_LATER_MARKER'));
        expect(mem['text'] as String, contains('User turn '));
        expect((mem['text'] as String).length, lessThanOrEqualTo(1000));
        expect(mem['text'] as String, isNot(contains('SYNTHETIC ANSWER')));

        // Other profiles never receive the statement.
        await local.createProfile('Synthetic B', DateTime(2010), '', true);
        recall.plan = '{"action":"conversation","query":""}';
        final callsBeforeOtherProfile = recall.answerInputs.length;
        await local.ask('What about zephyrin?');
        expect(recall.answerInputs.length, callsBeforeOtherProfile);
        expect(
          local.messages.last.text,
          isNot(contains('SYNTHETIC_LATER_MARKER')),
        );

        // Deleting the origin session removes the recall everywhere.
        await local.selectProfile(a);
        await local.deleteConversation(originId);
        await local.newConversation();
        final callsAfterDelete = recall.answerInputs.length;
        await local.ask('What did I note about zephyrin?');
        expect(recall.answerInputs.length, callsAfterDelete);
        expect(
          local.messages.last.text,
          isNot(contains('SYNTHETIC_LATER_MARKER')),
        );
      } finally {
        local.dispose();
      }
    },
  );
}
