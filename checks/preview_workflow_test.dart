import 'dart:convert';
import 'dart:typed_data';

import 'package:ayumitra/preview/demo_controller.dart';
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
      await controller.createProfile('Example child', 5, '', true);
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
      await controller.createProfile('Example one', 8, '', true);
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
      await controller.createProfile('Example two', 42, '', false);
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
      await controller.createProfile('Example child', 5, '', true);
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
}
