import 'dart:convert';
import 'dart:typed_data';

import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'preview workflow stays in memory and preserves synthetic source evidence',
    () async {
      final controller = DemoController();
      await controller.initialize();
      expect(controller.isPreview, isTrue);
      expect(controller.loaded, isTrue);
      expect(controller.data.profiles, isEmpty);
      await controller.createProfile('Example child', _birthDate(5), '', true);
      await controller.importSample(Uint8List(0));
      expect(controller.reports, hasLength(4));
      expect(controller.reports.last.eventDate, isNull);
      expect(
        controller.reports.every((r) => r.name.startsWith('Synthetic')),
        isTrue,
      );
      await controller.ask('Compare my hemoglobin results');
      final answer = controller.messages.last;
      expect(answer.text, contains('scripted response'));
      expect(answer.text, contains('11.2'));
      expect(answer.text, contains('10.8'));
      expect(answer.text, isNot(contains('| Report | Clinical date |')));
      expect(
        answer.text.indexOf('| Name | Value |'),
        lessThan(answer.text.indexOf('## Reports used')),
      );
      expect(answer.hits.every((hit) => hit.report.type == 'lab'), isTrue);
      expect(answer.web, isEmpty);
      final report = controller.reports.firstWhere(
        (r) => r.facts.first.value == '11.2',
      );
      final original = utf8.decode(await controller.original(report));
      await controller.correctFact(report, report.facts.first, '11.3');
      final changed = controller.reports.firstWhere((r) => r.id == report.id);
      expect(changed.summaryMarkdown, isNull);
      expect(changed.facts.first.corrected, isTrue);
      expect(changed.facts.first.originalValue, '11.2');
      expect(utf8.decode(await controller.original(changed)), original);
      await controller.retry(changed);
      expect(
        controller.reports.firstWhere((r) => r.id == report.id).summaryMarkdown,
        contains('11.3 (user corrected)'),
      );
      await controller.initialize();
      expect(controller.data.reports, isEmpty);
      expect(controller.messages, isEmpty);
      controller.dispose();
    },
  );

  test(
    'preview source access and follow-up results are scoped to the profile',
    () async {
      final controller = DemoController();
      await controller.initialize();
      await controller.createProfile('Example one', _birthDate(8), '', true);
      await controller.attachReport();
      await controller.attachReport();
      final firstProfile = controller.profile!.id;
      final firstReport = controller.reports.first;
      await controller.ask('Find my medicines');
      await controller.ask('Show it again');
      expect(
        controller.messages.last.hits.every(
          (hit) => hit.report.type == 'prescription',
        ),
        isTrue,
      );
      await controller.createProfile('Example two', _birthDate(42), '', false);
      expect(controller.reports, isEmpty);
      expect(controller.messages, isEmpty);
      await expectLater(controller.original(firstReport), throwsStateError);
      await controller.attachReport();
      expect(
        controller.reports.every((r) => r.profileId != firstProfile),
        isTrue,
      );
      controller.dispose();
    },
  );

  test(
    'typed attachment and follow-up references use synthetic reports',
    () async {
      final controller = DemoController();
      await controller.initialize();
      await controller.createProfile('Example child', _birthDate(5), '', true);
      await controller.ask('Add this report');
      expect(controller.reports, hasLength(1));
      expect(controller.messages.first.isUser, isTrue);
      expect(controller.messages.last.text, contains('scripted response'));
      expect(controller.messages.last.text, contains('No file was uploaded'));
      await controller.importSample(Uint8List(0));
      await controller.ask('Find my medicines');
      await controller.ask('Compare my hemoglobin results');
      expect(
        controller.messages.last.hits.every((hit) => hit.report.type == 'lab'),
        isTrue,
      );
      await controller.ask('Compare previous');
      final answer = controller.messages.last;
      expect(answer.text, contains('11.2'));
      expect(answer.text, contains('10.8'));
      expect(answer.text, isNot(contains('Amoxicillin')));
      expect(answer.hits.every((hit) => hit.report.type == 'lab'), isTrue);
      expect(answer.web, isEmpty);
      controller.dispose();
    },
  );

  test(
    'conversation selection, recall, and deletion remain profile scoped',
    () async {
      final controller = DemoController();
      await controller.initialize();
      await controller.createProfile('Example child', _birthDate(5), '', true);
      final firstProfileId = controller.profile!.id;
      await controller.importSample(Uint8List(0));
      await controller.ask('Find my hemoglobin results');
      final firstId = controller.activeSession!.id;
      expect(controller.activeSession!.title, 'Find my hemoglobin results');
      expect(
        controller.data.memories.single.text,
        contains('Find my hemoglobin results'),
      );

      await controller.newConversation();
      expect(controller.messages, isEmpty);
      await controller.ask('Compare previous');
      final secondId = controller.activeSession!.id;
      expect(controller.messages.last.text, contains('earlier conversation'));
      expect(controller.messages.last.text, contains('11.2'));
      expect(controller.messages.last.text, contains('10.8'));
      expect(
        controller.messages.last.hits.every((hit) => hit.report.type == 'lab'),
        isTrue,
      );

      await controller.newConversation();
      await controller.ask('Find my medicines');
      await controller.selectConversation(firstId);
      expect(controller.activeSession!.id, firstId);
      expect(controller.messages.last.hits, isNotEmpty);
      expect(
        controller.messages.last.hits.every(
          (hit) => hit.report.profileId == firstProfileId,
        ),
        isTrue,
      );
      await controller.createProfile(
        'Example adult',
        _birthDate(42),
        '',
        false,
      );
      await controller.ask('Hello');
      final otherId = controller.activeSession!.id;
      await controller.selectProfile(firstProfileId);
      expect(controller.activeSession!.id, firstId);
      await controller.deleteConversation(otherId);
      expect(
        controller.data.sessions.any((session) => session.id == otherId),
        isTrue,
      );
      await controller.deleteConversation(secondId);
      expect(
        controller.data.sessions.any((session) => session.id == secondId),
        isFalse,
      );
      expect(
        controller.data.memories.any((memory) => memory.sessionId == secondId),
        isFalse,
      );
      expect(controller.reports, hasLength(4));
      await controller.deleteConversation(firstId);
      expect(
        controller.data.sessions.any((session) => session.id == firstId),
        isFalse,
      );
      expect(
        controller.data.memories.any((memory) => memory.sessionId == firstId),
        isFalse,
      );
      expect(controller.activeSession?.id, isNot(firstId));
      expect(controller.reports, hasLength(4));
      controller.dispose();
    },
  );

  test(
    'DOB changes update event ages and extended thinking stays scripted',
    () async {
      final controller = DemoController();
      await controller.initialize();
      await controller.createProfile('Example child', _birthDate(5), '', true);
      final profileId = controller.profile!.id;
      await controller.attachReport();
      final previousAge = ageAtEvent(
        controller.profile!,
        controller.reports.first.eventDate,
      );
      await controller.updateProfile(
        profileId,
        name: 'Updated example',
        dateOfBirth: _birthDate(6),
        history: 'Invented background',
        isChild: true,
      );
      final newAge = ageAtEvent(
        controller.profile!,
        controller.reports.first.eventDate,
      );
      expect(newAge, isNot(previousAge));
      expect(controller.reports.first.summaryMarkdown, contains(newAge));
      controller.setExtendedThinking(true);
      await controller.ask('Find my hemoglobin results');
      expect(
        controller.messages.last.text,
        contains('Extended thinking · scripted review'),
      );
      expect(
        controller.messages.last.text,
        contains('No AI model or web search ran'),
      );
      expect(controller.messages.last.web, isEmpty);
      expect(controller.busy, isFalse);
      expect(controller.intelligence.available, isFalse);
      expect(controller.embeddings.available, isFalse);
      expect(controller.webSearch.available, isFalse);
      controller.dispose();
    },
  );

  test(
    'complex research requests automatically use a scripted review',
    () async {
      final controller = DemoController();
      await controller.initialize();
      await controller.createProfile('Example child', _birthDate(5), '', true);
      await controller.importSample(Uint8List(0));
      for (final request in [
        'Deep research my hemoglobin history',
        'Research thoroughly my blood reports',
      ]) {
        expect(controller.extendedThinking, isFalse);
        await controller.ask(request);
        expect(
          controller.messages.last.text,
          contains('Extended thinking · scripted review'),
        );
        expect(
          controller.messages.last.text,
          contains('Automatically selected for this research request'),
        );
        expect(
          controller.messages.last.text,
          contains('No AI model or web search ran'),
        );
        expect(
          controller.messages.last.hits.every(
            (hit) => hit.report.type == 'lab',
          ),
          isTrue,
        );
        expect(controller.messages.last.web, isEmpty);
        expect(controller.extendedThinking, isFalse);
        expect(controller.busy, isFalse);
      }
      controller.dispose();
    },
  );
}

DateTime _birthDate(int years) {
  final now = DateTime.now();
  return DateTime(now.year - years, now.month, now.day);
}
