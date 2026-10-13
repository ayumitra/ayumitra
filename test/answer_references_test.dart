import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReferenceModel extends LocalIntelligence {
  _ReferenceModel({required this.withWeb});
  final bool withWeb;
  bool malformed = false;
  final summaryInputs = <Map>[];
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
      return jsonEncode({
        'actions': [
          {'action': 'search_records', 'query': 'hemoglobin'},
          if (withWeb)
            {'action': 'web_search', 'query': 'amoxicillin official label'},
        ],
      });
    }
    final data = jsonDecode(input) as Map;
    summaryInputs.add(data);
    if (malformed) return 'UNSUPPORTED_MEDICAL_CLAIM [p1-l1]';
    final evidence = (data['evidence'] as List).cast<Map>();
    final used = evidence.singleWhere((row) => row['reportName'] == 'Used.txt');
    final fileReference = used['sourceId'];
    final web = (data['webSources'] as List).cast<Map>();
    final requirements = data['answerRequirements'] as Map?;
    final observationId = requirements?['requiredUserObservationSourceId'];
    return '${observationId == null ? '' : 'User-provided context [$observationId]. '}File finding [$fileReference], repeated file reference [$fileReference]. '
        '${web.isEmpty ? '' : 'Public label [${web.singleWhere((row) => row['url'] == 'https://example.org/used')['sourceId']}].'}';
  }
}

class _PublicReferences extends WebSearch {
  @override
  bool get available => true;
  @override
  Future<List<WebSource>> search(String query) async => [
    for (final name in ['used', 'unused'])
      WebSource(
        id: 'provider-$name',
        title: 'Synthetic $name label',
        url: Uri.parse('https://example.org/$name'),
        excerpt: 'Synthetic $name snippet',
        retrievedAt: DateTime.utc(2026, 10, 13),
      ),
  ];
}

Report _report(String id, String profile, String name, String text) => Report(
  id: id,
  profileId: profile,
  name: name,
  extension: 'txt',
  digest: id,
  importedAt: DateTime.utc(2026, 10, 13),
  lines: [SourceLine(id: 'p1-l1', page: 1, text: text)],
);

Future<({AppController controller, EncryptedVault vault})> _native(
  _ReferenceModel model,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'ayumitra-answer-refs-',
  );
  final vault = EncryptedVault(
    directory: directory,
    key: await AesGcm.with256bits().newSecretKey(),
  );
  final controller =
      AppController(intelligence: model, webSearch: _PublicReferences())
        ..loaded = true
        ..vault = vault;
  addTearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });
  await controller.createProfile('Synthetic Person', DateTime(2000), '', false);
  final owner = controller.profile!.id;
  controller.data = controller.data.copy(
    reports: [
      _report(
        'used-report',
        owner,
        'Used.txt',
        'hemoglobin value from used report',
      ),
      _report(
        'unused-report',
        owner,
        'Unused.txt',
        'hemoglobin value from unused report',
      ),
      _report(
        'foreign-report',
        'other-profile',
        'Foreign.txt',
        'hemoglobin foreign private report',
      ),
    ],
  );
  await vault.save(controller.data);
  return (controller: controller, vault: vault);
}

Future<DemoController> _browser(_ReferenceModel model) async {
  final controller = DemoController(intelligence: model);
  await controller.initialize();
  addTearDown(controller.dispose);
  await controller.createProfile('Synthetic Person', DateTime(2000), '', false);
  await controller.importBytes(
    'Used.txt',
    'txt',
    Uint8List.fromList(utf8.encode('hemoglobin used source')),
  );
  await controller.importBytes(
    'Unused.txt',
    'txt',
    Uint8List.fromList(utf8.encode('hemoglobin unused source')),
  );
  return controller;
}

void main() {
  test(
    'native mixed file and web references show and encrypt only cited canonical sources',
    () async {
      final model = _ReferenceModel(withWeb: true);
      final setup = await _native(model);
      final controller = setup.controller;
      final request =
          'SYNTHETIC_FULL_USER_TURN ${'context ' * 400} Explain hemoglobin and amoxicillin';
      await controller.ask(request);
      final prompt = model.summaryInputs.single;
      expect((prompt['evidence'] as List).length, 2);
      expect((prompt['webSources'] as List).length, 2);
      expect(jsonEncode(prompt), isNot(contains('foreign private report')));
      final answer = controller.messages.last;
      expect(answer.text, contains('[used-report/p1-l1]'));
      expect(answer.text, contains('[web-1]'));
      expect(answer.hits.map((hit) => hit.citation), ['used-report/p1-l1']);
      expect(answer.web.map((source) => source.id), ['web-1']);
      final saved = await setup.vault.read();
      final session = saved.sessions.single;
      expect(
        session.turns.singleWhere((turn) => turn.role == 'user').text,
        request,
      );
      final stored = session.turns.last;
      expect(stored.reportCitations, ['used-report/p1-l1']);
      expect(stored.webSources.map((source) => source.url), [
        'https://example.org/used',
      ]);
      expect(stored.webSources.single.excerpt, 'Synthetic used snippet');
      expect(stored.webSources.single.retrievedAt, DateTime.utc(2026, 10, 13));
      final raw = latin1.decode(
        await File('${setup.vault.directory.path}/index.enc').readAsBytes(),
      );
      expect(raw, isNot(contains('SYNTHETIC_FULL_USER_TURN')));
      expect(raw, isNot(contains('Synthetic used snippet')));
      controller.restoreConversation();
      expect(controller.messages.last.hits.map((hit) => hit.citation), [
        'used-report/p1-l1',
      ]);
      expect(controller.messages.last.web.map((source) => source.id), [
        'web-1',
      ]);
    },
  );

  test(
    'browser aliases persist only the used owned file, leaving retrieved unused files unreferenced',
    () async {
      final model = _ReferenceModel(withWeb: false);
      final controller = await _browser(model);
      final used = controller.reports.singleWhere(
        (report) => report.name == 'Used.txt',
      );
      await controller.ask('Explain hemoglobin.');
      expect((model.summaryInputs.single['evidence'] as List).length, 2);
      final answer = controller.messages.last;
      expect(answer.text, contains('[${used.id}/p1-l1]'));
      expect(answer.hits.map((hit) => hit.citation), ['${used.id}/p1-l1']);
      expect(answer.web, isEmpty);
      expect(controller.activeSession!.turns.last.reportCitations, [
        '${used.id}/p1-l1',
      ]);
      expect(controller.data.reports.length, 2);
    },
  );

  for (final browser in [false, true]) {
    test(
      '${browser ? 'browser' : 'native'} refuses partial references and labels retrieved fallback evidence',
      () async {
        final model = _ReferenceModel(withWeb: !browser)..malformed = true;
        final AppController controller = browser
            ? await _browser(model)
            : (await _native(model)).controller;
        await controller.ask('Explain hemoglobin.');
        final answer = controller.messages.last;
        expect(answer.text, contains('could not validate'));
        expect(answer.text, contains('Retrieved evidence · fallback'));
        expect(answer.text, isNot(contains('UNSUPPORTED_MEDICAL_CLAIM')));
        expect(answer.hits.length, 2);
        expect(
          answer.hits.every(
            (hit) => hit.report.profileId == controller.profile!.id,
          ),
          true,
        );
        expect(controller.activeSession!.turns.last.reportCitations.length, 2);
        expect(answer.web.length, browser ? 0 : 2);
      },
    );
  }
}
