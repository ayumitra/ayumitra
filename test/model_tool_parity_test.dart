import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/frontier_models.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/services/frontier_gateway.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_research.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RoleCall {
  const _RoleCall(this.instruction, this.payload);
  final String instruction;
  final Map<String, dynamic> payload;
}

/// The same deterministic responder runs behind each backend. Assertions test
/// the real shared planner/tool executor, persistence and source gates rather
/// than assigning a separate set of fake tool results to the cloud model.
class _ToolScript {
  final calls = <_RoleCall>[];
  List<Map<String, String>> actions = [
    {'action': 'search_records', 'query': 'hemoglobin'},
    {
      'action': 'web_search',
      'query': 'oxygen saturation basics official guidance',
    },
  ];
  String rewrittenQuery = 'oxygen saturation public guidance';
  int researchPlans = 0;
  int researchAssessments = 0;

  Future<String> respond(String instruction, String input) async {
    Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(jsonDecode(input) as Map);
    } on FormatException {
      payload = {'rawRequest': input};
    }
    calls.add(_RoleCall(instruction, payload));
    if (instruction.startsWith(plannerPrompt)) {
      return jsonEncode({'actions': actions});
    }
    if (instruction.startsWith(researchPlannerPrompt)) {
      researchPlans++;
      return jsonEncode({
        'actions': [
          {
            'action': 'web_search',
            'query': researchPlans == 1
                ? 'oxygen saturation basics official guidance'
                : 'oxygen saturation measurement reliability',
          },
        ],
      });
    }
    if (instruction.startsWith(researchAssessorPrompt)) {
      researchAssessments++;
      return jsonEncode({
        'missingTopics': researchAssessments == 1
            ? ['oxygen saturation measurement reliability']
            : [],
      });
    }
    if (instruction.startsWith('Rewrite the user question')) {
      return rewrittenQuery;
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
        ? 'SYNTHETIC_GENERAL_ANSWER.'
        : 'SYNTHETIC_TOOL_ANSWER ${ids.map((id) => '[$id]').join(' ')}.';
  }

  List<_RoleCall> get finalCalls => calls
      .where(
        (call) =>
            call.instruction.startsWith(summaryPrompt) ||
            call.instruction.startsWith(userObservationPrompt),
      )
      .toList();
}

class _ToolLocal extends LocalIntelligence {
  _ToolLocal(this.script);
  final _ToolScript script;
  bool ready = true;
  int calls = 0;
  @override
  bool get available => ready;
  @override
  Future<String> generate(String instruction, String input) {
    calls++;
    return script.respond(instruction, input);
  }
}

class _ToolGateway extends FrontierGateway {
  _ToolGateway(this.script);
  final _ToolScript script;
  int calls = 0;
  @override
  Future<String> generate({
    required Uri endpoint,
    required String provider,
    required String model,
    required String apiKey,
    required String instruction,
    required String input,
  }) {
    calls++;
    expect(endpoint, FrontierGateway.providerEndpoint(provider));
    expect(apiKey, 'SYNTHETIC_PROVIDER_KEY');
    return script.respond(instruction, input);
  }
}

class _NoVectors extends LocalEmbeddings {
  @override
  bool get available => false;
}

class _PublicSources extends WebSearch {
  final queries = <String>[];
  @override
  bool get available => true;
  @override
  Future<List<WebSource>> search(String query) async {
    queries.add(query);
    return [
      WebSource(
        id: 'provider-source',
        title: 'Synthetic public reference',
        url: Uri.parse('https://example.org/official-${queries.length}'),
        excerpt: 'PUBLIC_SNIPPET_ONLY_${queries.length}',
        retrievedAt: DateTime.utc(2024, 3, 15),
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final cloud in [false, true]) {
    group(cloud ? 'selected cloud shared tools' : 'local shared tools', () {
      late Directory directory;
      late AppController c;
      late _ToolScript script;
      late _ToolLocal local;
      late _ToolGateway gateway;
      late _PublicSources web;
      final event = DateTime.utc(2024, 3, 14);

      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        directory = await Directory.systemTemp.createTemp(
          'ayumitra-tool-parity-',
        );
        script = _ToolScript();
        local = _ToolLocal(script);
        gateway = _ToolGateway(script);
        web = _PublicSources();
        final ownSession = ConversationSession(
          id: 'alice-origin',
          profileId: 'alice',
          title: 'Synthetic own history',
          createdAt: event,
          updatedAt: event,
          turns: [
            ConversationTurn(
              id: 'alice-user',
              role: 'user',
              text:
                  'I reported hemoglobin 13 g/dL on 2024-04-03. ALICE_HISTORY_STATEMENT',
              createdAt: DateTime.utc(2024, 4, 3),
            ),
          ],
        );
        final foreign = ConversationSession(
          id: 'bob-origin',
          profileId: 'bob',
          title: 'Synthetic other history',
          createdAt: event,
          updatedAt: event,
          turns: [
            ConversationTurn(
              id: 'bob-user',
              role: 'user',
              text: 'BOB_CONVERSATION_SECRET hemoglobin',
              createdAt: event,
            ),
          ],
        );
        c =
            AppController(
                intelligence: local,
                embeddings: _NoVectors(),
                webSearch: web,
                frontierGateway: gateway,
              )
              ..loaded = true
              ..activeProfileId = 'alice'
              ..data = VaultData(
                activeProfileId: 'alice',
                profiles: [
                  Profile(
                    id: 'alice',
                    name: 'Synthetic Alice',
                    history: 'ALICE_PROFILE_HISTORY',
                    dateOfBirth: DateTime(2020),
                  ),
                  Profile(
                    id: 'bob',
                    name: 'Synthetic Bob',
                    history: 'BOB_HISTORY_SECRET',
                    dateOfBirth: DateTime(2000),
                  ),
                ],
                sessions: [ownSession, foreign],
                memories: [
                  buildConversationMemory(ownSession),
                  buildConversationMemory(foreign),
                ],
                reports: [
                  Report(
                    id: 'alice-report',
                    profileId: 'alice',
                    name: 'synthetic-alice.txt',
                    extension: 'txt',
                    digest: 'synthetic-alice',
                    importedAt: event,
                    eventDate: event,
                    status: ReportStatus.ready,
                    lines: const [
                      SourceLine(
                        id: 'p1-l1',
                        page: 1,
                        text: 'Hemoglobin 11.2 g/dL ALICE_REPORT_SOURCE',
                      ),
                    ],
                  ),
                  Report(
                    id: 'bob-report',
                    profileId: 'bob',
                    name: 'synthetic-bob.txt',
                    extension: 'txt',
                    digest: 'synthetic-bob',
                    importedAt: event,
                    eventDate: event,
                    status: ReportStatus.ready,
                    lines: const [
                      SourceLine(
                        id: 'p1-l1',
                        page: 1,
                        text: 'Hemoglobin 17.9 g/dL BOB_REPORT_SECRET',
                      ),
                    ],
                  ),
                ],
              )
              ..vault = EncryptedVault(
                directory: directory,
                key: await AesGcm.with256bits().newSecretKey(),
              );
        await c.vault.save(c.data);
        if (cloud) {
          await c.setFrontierKey(
            FrontierModels.openAiProvider,
            'SYNTHETIC_PROVIDER_KEY',
          );
          await c.acceptFrontierDisclosure();
          await c.setAllowRemoteAi(true);
          await c.setFrontierChatMode(true);
          expect(c.failure, isNull);
        }
        expect(local.calls, 0);
        expect(gateway.calls, 0);
      });
      tearDown(() async {
        c.dispose();
        await directory.delete(recursive: true);
      });

      Future<void> ask(String question) => c.askWithSelectedModel(question);
      void expectSelectedBackendOnly() {
        expect(cloud ? gateway.calls : local.calls, greaterThan(0));
        expect(cloud ? local.calls : gateway.calls, 0);
      }

      void expectNoForeignContext() {
        for (final call in script.calls) {
          final payload = jsonEncode(call.payload);
          for (final marker in [
            'BOB_HISTORY_SECRET',
            'BOB_REPORT_SECRET',
            'BOB_CONVERSATION_SECRET',
          ]) {
            expect(payload, isNot(contains(marker)));
          }
        }
      }

      test(
        'report/date retrieval and public citations use the same executor',
        () async {
          await ask(
            'What was my hemoglobin on March 14, 2024? Explain using public sources.',
          );
          expect(c.failure, isNull);
          expectSelectedBackendOnly();
          expect(web.queries, ['oxygen saturation basics official guidance']);
          expect(
            script.calls.any(
              (call) => call.instruction.startsWith(plannerPrompt),
            ),
            isTrue,
          );
          final payload = script.finalCalls.last.payload;
          expect(payload['currentDateTime'], isA<String>());
          final evidence = jsonEncode(payload['evidence']);
          expect(evidence, contains('11.2 g/dL'));
          expect(evidence, contains('2024-03-14'));
          expect(evidence, isNot(contains('17.9')));
          expect(c.messages.last.hits.map((hit) => hit.report.id), [
            'alice-report',
          ]);
          expect(c.messages.last.text, contains('[alice-report/p1-l1]'));
          expect(c.messages.last.text, contains('[web-1]'));
          expect(c.messages.last.web.single.url.host, 'example.org');
          expectNoForeignContext();
        },
      );

      test(
        'private public-query proposals are sanitized before network dispatch',
        () async {
          script.actions = [
            {
              'action': 'web_search',
              'query': 'Synthetic Bob oxygen saturation 97%',
            },
          ];
          await ask('Explain oxygen saturation using public sources');
          expect(c.failure, isNull);
          expectSelectedBackendOnly();
          expect(web.queries, ['oxygen saturation public guidance']);
          expect(
            web.queries.any(
              (query) => query.contains('Bob') || query.contains('97'),
            ),
            isFalse,
          );
          expect(
            script.calls.any(
              (call) =>
                  call.instruction.startsWith('Rewrite the user question'),
            ),
            isTrue,
          );
          expect(c.messages.last.web, hasLength(1));
          expectNoForeignContext();
        },
      );

      test(
        'a still-private rewritten web query is withheld in either backend',
        () async {
          script.actions = [
            {'action': 'web_search', 'query': 'my oxygen saturation 98%'},
          ];
          script.rewrittenQuery = 'Synthetic Alice oxygen saturation 98%';
          await ask('Explain oxygen saturation using public sources');
          expect(c.failure, isNull);
          expectSelectedBackendOnly();
          expect(web.queries, isEmpty);
          expect(c.messages.last.web, isEmpty);
          expect(c.messages.last.text.toLowerCase(), contains('privacy'));
        },
      );

      test(
        'the model can autonomously enter the same bounded research loop',
        () async {
          script.actions = [
            {'action': 'search_records', 'query': 'hemoglobin'},
            {'action': 'extended_thinking', 'query': ''},
          ];
          expect(c.extendedThinking, isFalse);
          await ask(
            'Explain oxygen saturation using reliable public information',
          );
          expect(c.failure, isNull);
          expectSelectedBackendOnly();
          expect(script.researchPlans, 2);
          expect(script.researchAssessments, 2);
          expect(web.queries, [
            'oxygen saturation basics official guidance',
            'oxygen saturation measurement reliability',
          ]);
          expect(c.messages.last.web, hasLength(2));
          expect(c.messages.last.text, contains('Extended thinking'));
          for (final call in script.calls.where(
            (call) => call.instruction.startsWith(researchPlannerPrompt),
          )) {
            expect(
              jsonEncode(call.payload),
              isNot(contains('PUBLIC_SNIPPET_ONLY')),
            );
          }
          expectNoForeignContext();
        },
      );

      test(
        'record_metric persists a dated owned reading through either backend',
        () async {
          script.actions = [
            {
              'action': 'record_metric',
              'query': jsonEncode({
                'kind': 'pulse',
                'value': 72,
                'unit': 'bpm',
                'date': '2024-03-14',
              }),
            },
          ];
          await ask('Please record my pulse 72 bpm on 2024-03-14');
          expect(c.failure, isNull);
          expectSelectedBackendOnly();
          final reading = c.data.vitals.single;
          expect(reading.profileId, 'alice');
          expect(reading.kind, VitalKind.pulse);
          expect(reading.value, 72);
          expect(reading.unit, 'bpm');
          expect(reading.measuredAt.year, 2024);
          expect(reading.measuredAt.month, 3);
          expect(reading.measuredAt.day, 14);
          expect(reading.source, 'user');
          expect(
            (await c.vault.read()).vitals.single.toJson(),
            reading.toJson(),
          );
          expect(c.messages.last.text, contains('Recorded pulse'));
          expectNoForeignContext();
        },
      );

      test(
        'record_metric rejects an impossible reading instead of persisting it',
        () async {
          script.actions = [
            {
              'action': 'record_metric',
              'query': jsonEncode({
                'kind': 'pulse',
                'value': 500,
                'unit': 'bpm',
                'date': '2024-03-14',
              }),
            },
          ];
          await ask('Please record my pulse 500 bpm on 2024-03-14');
          expectSelectedBackendOnly();
          expect(c.data.vitals, isEmpty);
          expect((await c.vault.read()).vitals, isEmpty);
          expect(
            c.messages.last.text.toLowerCase(),
            contains('could not record'),
          );
        },
      );

      test(
        'record_metric rejects a measurement dated before this profile was born',
        () async {
          script.actions = [
            {
              'action': 'record_metric',
              'query': jsonEncode({
                'kind': 'pulse',
                'value': 72,
                'unit': 'bpm',
                'date': '2019-03-14',
              }),
            },
          ];
          await ask('Please record my pulse 72 bpm on 2019-03-14');
          expectSelectedBackendOnly();
          expect(c.data.vitals, isEmpty);
          expect((await c.vault.read()).vitals, isEmpty);
          expect(
            c.messages.last.text.toLowerCase(),
            contains('could not record'),
          );
        },
      );

      test(
        'private saved-history lookup stays within the selected profile',
        () async {
          script.actions = [
            {'action': 'search_records', 'query': 'hemoglobin'},
          ];
          await ask('What did I report about hemoglobin?');
          expect(c.failure, isNull);
          expectSelectedBackendOnly();
          final payload = jsonEncode(script.finalCalls.last.payload);
          expect(payload, contains('ALICE_HISTORY_STATEMENT'));
          expect(payload, contains('2024-04-03'));
          expect(c.messages.last.text, contains('[conversation:alice-origin]'));
          expectNoForeignContext();
        },
      );

      if (cloud) {
        test(
          'selected cloud tools do not require the on-device chat model',
          () async {
            local.ready = false;
            await ask('What was my hemoglobin on March 14, 2024?');
            expect(c.failure, isNull);
            expectSelectedBackendOnly();
            expect(c.messages.last.text, contains('[alice-report/p1-l1]'));
          },
        );
      }
    });
  }
}
