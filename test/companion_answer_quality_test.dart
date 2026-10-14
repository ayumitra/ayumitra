import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/health_report.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/second_opinion_draft.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _QualityCall {
  const _QualityCall(this.instruction, this.payload);
  final String instruction;
  final Map<String, dynamic> payload;
}

/// These tests inspect the real controller's routing and owned evidence, not
/// simulated clinical reasoning. The fake only echoes the supplied citation
/// aliases so production source validation still runs on every answer.
class _QualityModel extends LocalIntelligence {
  final calls = <_QualityCall>[];
  bool webPlan = false;
  int invalidAnswersRemaining = 0;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    final payload = Map<String, dynamic>.from(jsonDecode(input) as Map);
    calls.add(_QualityCall(instruction, payload));
    if (instruction == plannerPrompt) {
      return jsonEncode({
        'actions': [
          {'action': 'search_records', 'query': 'hemoglobin'},
          if (webPlan)
            {'action': 'web_search', 'query': 'oxygen saturation explanation'},
        ],
      });
    }
    if (invalidAnswersRemaining > 0) {
      invalidAnswersRemaining--;
      return 'SYNTHETIC unsupported source [S999].';
    }
    final ids = <String>{};
    void collect(dynamic value) {
      if (value is Map) {
        final source = value['sourceId'];
        if (source is String && RegExp(r'^S\d+$').hasMatch(source)) {
          ids.add(source);
        }
        for (final child in value.values) {
          collect(child);
        }
      } else if (value is List) {
        for (final child in value) {
          collect(child);
        }
      }
    }

    collect(payload);
    return ids.isEmpty
        ? '## General information\nSYNTHETIC educational explanation.'
        : '## Synthetic draft\nSYNTHETIC source-grounded answer '
              '${ids.map((id) => '[$id]').join(' ')}.';
  }

  List<_QualityCall> get answers =>
      calls.where((call) => call.instruction != plannerPrompt).toList();
}

class _NoDeviceEmbeddings extends LocalEmbeddings {
  @override
  bool get available => false;
}

class _QualityWeb extends WebSearch {
  bool enabled = false;
  final queries = <String>[];

  @override
  bool get available => enabled;

  @override
  Future<List<WebSource>> search(String query) async {
    queries.add(query);
    return [
      WebSource(
        id: 'synthetic-web',
        title: 'Synthetic public reference',
        url: Uri.parse('https://example.org/public-education'),
        excerpt: 'SYNTHETIC_PUBLIC_INFORMATION',
        retrievedAt: DateTime.utc(2026, 10, 14),
      ),
    ];
  }
}

Report _qualityReport(
  String id,
  String text, {
  String owner = 'alice',
  DateTime? date,
  bool fallback = false,
}) => Report(
  id: id,
  profileId: owner,
  name: '$id.pdf',
  extension: 'pdf',
  digest: 'synthetic-$id',
  importedAt: DateTime(2026, 10, 13),
  eventDate: date ?? DateTime.utc(2026, 3, 14),
  dateIsFallback: fallback,
  status: ReportStatus.ready,
  lines: [SourceLine(id: 'p1-l1', page: 1, text: text)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final preview in [false, true]) {
    group(preview ? 'browser shared answer pipeline' : 'native answer pipeline', () {
      late AppController c;
      late _QualityModel model;
      late _QualityWeb web;
      Directory? directory;

      setUp(() async {
        model = _QualityModel();
        web = _QualityWeb();
        final embeddings = _NoDeviceEmbeddings();
        c = preview
            ? DemoController(
                intelligence: model,
                embeddings: embeddings,
                webSearch: web,
              )
            : AppController(
                intelligence: model,
                embeddings: embeddings,
                webSearch: web,
              );
        if (!preview) {
          directory = await Directory.systemTemp.createTemp(
            'ayumitra-answer-quality-',
          );
          c.vault = EncryptedVault(
            directory: directory!,
            key: await AesGcm.with256bits().newSecretKey(),
          );
        }
        c
          ..loaded = true
          ..activeProfileId = 'alice'
          ..data = VaultData(
            activeProfileId: 'alice',
            profiles: [
              Profile(
                id: 'alice',
                name: 'Synthetic Alice',
                history: '',
                dateOfBirth: DateTime(2000),
              ),
              Profile(
                id: 'bob',
                name: 'Synthetic Bob',
                history: 'BOB_PRIVATE_HISTORY',
                dateOfBirth: DateTime(2001),
              ),
            ],
          );
      });

      tearDown(() async {
        c.dispose();
        if (directory != null) {
          await directory!.delete(recursive: true);
          directory = null;
        }
      });

      test(
        'health report composes from dated user chat without uploaded reports',
        () async {
          await c.ask('My hemoglobin was 13 g/dL on 2026-10-13');
          final observation = c.activeSession!.turns.firstWhere(
            (turn) => turn.role == 'user',
          );
          expect(
            model.answers.last.instruction,
            startsWith(userObservationPrompt),
          );
          await c.appendConversationEntry(
            ChatEntry('ASSISTANT_FICTION_DO_NOT_USE', isUser: false),
          );
          model.calls.clear();

          await c.ask('Craft a health report from what I told you');

          expect(c.failure, isNull);
          expect(c.data.reports, isEmpty);
          final call = model.answers.last;
          expect(call.instruction, startsWith(healthReportPrompt));
          expect(call.instruction, isNot(startsWith(userObservationPrompt)));
          final payload = jsonEncode(call.payload);
          expect(payload, contains('13 g/dL'));
          expect(payload, contains('2026-10-13'));
          expect(payload, contains(observation.createdAt.toIso8601String()));
          expect(payload, isNot(contains('ASSISTANT_FICTION_DO_NOT_USE')));
          expect(payload, isNot(contains('BOB_PRIVATE_HISTORY')));
          expect(c.messages.last.text, contains('[conversation:'));
          expect(c.messages.last.text, isNot(contains('Do you have a report')));
        },
      );

      test(
        'recorded vitals feed both questions and the health-report role by owner',
        () async {
          await c.recordVital(
            VitalKind.bloodPressure,
            120,
            diastolic: 80,
            measuredAt: DateTime(2026, 10, 13, 8),
            note: 'ALICE_RECORDED_READING',
          );
          await c.recordVital(
            VitalKind.spo2,
            98,
            measuredAt: DateTime(2026, 10, 13, 8),
          );
          final aliceIds = c.vitals.map((vital) => vital.id).toList();
          await c.selectProfile('bob');
          await c.recordVital(
            VitalKind.temperature,
            39,
            measuredAt: DateTime(2026, 10, 13, 9),
            note: 'BOB_PRIVATE_READING',
          );
          await c.selectProfile('alice');
          expect(c.vitals.map((vital) => vital.id), unorderedEquals(aliceIds));
          for (final request in [
            'What is my latest blood pressure?',
            'Craft a health report',
          ]) {
            model.calls.clear();
            await c.ask(request);
            expect(c.failure, isNull);
            expect(model.answers, isNotEmpty);
            final payload = jsonEncode(model.answers.last.payload);
            expect(payload, contains('120'));
            expect(payload, contains('80'));
            expect(payload, contains('mmHg'));
            expect(payload, contains('2026-10-13'));
            expect(payload, isNot(contains('BOB_PRIVATE_READING')));
            expect(payload, isNot(contains('BOB_PRIVATE_HISTORY')));
          }
          if (!preview) {
            final saved = await c.vault.read();
            expect(
              saved.vitals.where((vital) => vital.profileId == 'alice'),
              hasLength(2),
            );
            expect(
              saved.vitals.where((vital) => vital.profileId == 'bob'),
              hasLength(1),
            );
          }
        },
      );

      test(
        'a general medical explanation reaches local knowledge without private evidence',
        () async {
          await c.ask('What is oxygen saturation?');
          expect(c.failure, isNull);
          expect(model.answers, isNotEmpty);
          final call = model.answers.last;
          expect(call.instruction, startsWith(summaryPrompt));
          expect(
            jsonEncode(call.payload),
            contains('generalInformationAllowed'),
          );
          expect(c.messages.last.text, contains('General information'));
          expect(
            c.messages.last.text,
            isNot(contains('couldn’t find supporting')),
          );
          expect(c.messages.last.text, isNot(contains('[S')));
          expect(web.queries, isEmpty);
        },
      );

      test(
        'public corroboration has web references without sending private readings',
        () async {
          web.enabled = true;
          model.webPlan = true;
          await c.recordVital(
            VitalKind.spo2,
            97,
            measuredAt: DateTime(2026, 10, 13),
            note: 'ALICE_PRIVATE_READING',
          );
          await c.ask('Explain oxygen saturation using public sources');
          expect(c.failure, isNull);
          expect(web.queries, ['oxygen saturation explanation']);
          expect(web.queries.single, isNot(contains('97')));
          expect(web.queries.single, isNot(contains('Alice')));
          final payload = jsonEncode(model.answers.last.payload);
          expect(payload, contains('SYNTHETIC_PUBLIC_INFORMATION'));
          expect(payload, contains('2026-10-14'));
          expect(c.messages.last.web.single.url.host, 'example.org');
          expect(c.messages.last.text, contains('[web-'));
        },
      );

      test(
        'an explicitly older report date beats a newer user-reported value',
        () async {
          c.data = c.data.copy(
            reports: [
              _qualityReport('old-report', 'Hemoglobin 11.2 g/dL'),
              _qualityReport(
                'later-report',
                'Hemoglobin 12.6 g/dL',
                date: DateTime.utc(2026, 4, 3),
              ),
              _qualityReport(
                'foreign-report',
                'BOB_PRIVATE_REPORT',
                owner: 'bob',
              ),
            ],
          );
          await c.ask('My hemoglobin was 13 g/dL on 2026-10-13');
          model.calls.clear();
          await c.ask('What was my hemoglobin on March 14, 2026?');
          expect(c.failure, isNull);
          final call = model.answers.last;
          expect(call.instruction, startsWith(summaryPrompt));
          expect(call.instruction, isNot(startsWith(userObservationPrompt)));
          final evidence = call.payload['evidence'] as List;
          expect(jsonEncode(evidence), contains('11.2 g/dL'));
          expect(jsonEncode(evidence), isNot(contains('12.6 g/dL')));
          expect(jsonEncode(evidence), isNot(contains('13 g/dL')));
          expect(
            jsonEncode(call.payload),
            isNot(contains('BOB_PRIVATE_REPORT')),
          );
          expect(c.messages.last.hits.map((hit) => hit.report.id), [
            'old-report',
          ]);
        },
      );

      test(
        'date-only request retains matching rows even with no matching search words',
        () async {
          c.data = c.data.copy(
            reports: [
              _qualityReport('dated-a', 'SYNTHETIC_ALPHA'),
              _qualityReport('dated-b', 'SYNTHETIC_BETA'),
              _qualityReport(
                'different-date',
                'SYNTHETIC_OTHER_EVENT',
                date: DateTime.utc(2026, 4, 3),
              ),
            ],
          );
          await c.ask('Show the reports on March 14, 2026');
          expect(c.failure, isNull);
          final evidence = model.answers.last.payload['evidence'] as List;
          expect(jsonEncode(evidence), contains('SYNTHETIC_ALPHA'));
          expect(jsonEncode(evidence), contains('SYNTHETIC_BETA'));
          expect(
            jsonEncode(evidence),
            isNot(contains('SYNTHETIC_OTHER_EVENT')),
          );
          expect(
            c.messages.last.hits.map((hit) => hit.report.id),
            unorderedEquals(['dated-a', 'dated-b']),
          );
        },
      );

      test(
        'ambiguous numeric date asks for clarification without generating an answer',
        () async {
          c.data = c.data.copy(
            reports: [_qualityReport('dated-a', 'SYNTHETIC_ALPHA')],
          );
          await c.ask('Show my report from 03/04/2026');
          expect(c.failure, isNull);
          expect(model.answers, isEmpty);
          expect(c.messages.last.isUser, isFalse);
          expect(c.messages.last.text.toLowerCase(), contains('date'));
          expect(c.messages.last.hits, isEmpty);
        },
      );

      test(
        'an agentic clinician brief uses the dedicated draft role',
        () async {
          await c.ask('My temperature was 37 °C on 2026-10-13');
          model.calls.clear();
          await c.ask('Draft a second-opinion brief for my clinician');
          expect(c.failure, isNull);
          final call = model.answers.last;
          expect(call.instruction, startsWith(secondOpinionDraftPrompt));
          expect(jsonEncode(call.payload), contains('37 °C'));
          expect(jsonEncode(call.payload), contains('2026-10-13'));
          expect(c.messages.last.text, contains('[conversation:'));
        },
      );

      test(
        'invented source aliases are repaired before the answer is persisted',
        () async {
          c.data = c.data.copy(
            reports: [_qualityReport('dated-a', 'SYNTHETIC_ALPHA')],
          );
          model.invalidAnswersRemaining = 1;
          await c.ask('Show my reports from March 14, 2026');
          expect(c.failure, isNull);
          expect(model.answers, hasLength(2));
          expect(model.answers.last.payload, contains('outputRepair'));
          expect(c.messages.last.text, isNot(contains('S999')));
          expect(c.messages.last.text, contains('[dated-a/p1-l1]'));
          expect(
            c.activeSession!.turns.last.reportCitations,
            contains('dated-a/p1-l1'),
          );
        },
      );
    });
  }
}
