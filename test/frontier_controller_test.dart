import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/frontier_models.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/frontier_gateway.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _GatewayCall {
  _GatewayCall({
    required this.endpoint,
    required this.provider,
    required this.model,
    required this.apiKey,
    required this.instruction,
    required this.input,
  });
  final Uri endpoint;
  final String provider, model, apiKey, instruction, input;
}

class _Gateway extends FrontierGateway {
  final calls = <_GatewayCall>[];
  bool fail = false;
  final outputs = <String>[];
  void Function()? onGenerate;
  List<_GatewayCall> get plannerCalls => calls
      .where((call) => call.instruction.startsWith(plannerPrompt))
      .toList();
  List<_GatewayCall> get answerCalls => calls
      .where((call) => !call.instruction.startsWith(plannerPrompt))
      .toList();
  @override
  Future<String> generate({
    required Uri endpoint,
    required String provider,
    required String model,
    required String apiKey,
    required String instruction,
    required String input,
  }) async {
    calls.add(
      _GatewayCall(
        endpoint: endpoint,
        provider: provider,
        model: model,
        apiKey: apiKey,
        instruction: instruction,
        input: input,
      ),
    );
    onGenerate?.call();
    if (fail) throw const FrontierGatewayException('Synthetic gateway failure');
    if (instruction.startsWith(plannerPrompt)) {
      return '{"actions":[{"action":"search_records","query":"ALICE_REPORT_MARKER"}]}';
    }
    if (outputs.isNotEmpty) return outputs.removeAt(0);
    final payload = jsonDecode(input);
    final ids = <String>{};
    void collect(dynamic value) {
      if (value is Map) {
        final id = value['sourceId'];
        if (id is String && RegExp(r'^S\d+$').hasMatch(id)) ids.add(id);
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
    return 'SYNTHETIC_FRONTIER_ANSWER ${ids.map((id) => '[$id]').join(' ')}';
  }
}

class _Local extends LocalIntelligence {
  int calls = 0;
  @override
  bool get available => true;
  @override
  Future<String> generate(String instruction, String input) async {
    calls++;
    if (instruction.startsWith(plannerPrompt)) {
      return '{"actions":[{"action":"conversation","query":""}]}';
    }
    return 'Hello. I can help with your health questions.';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'SYNTHETIC-PROVIDER-KEY';
  const lookup = 'What does my saved ALICE_REPORT_MARKER report say?';
  const openAiEndpoint = 'https://api.openai.com/v1/responses';
  const anthropicEndpoint = 'https://api.anthropic.com/v1/messages';
  late Directory directory;
  late EncryptedVault vault;
  late _Gateway gateway;
  late _Local local;
  late AppController c;
  final now = DateTime(2026, 10, 14, 9);

  Profile owner(String id) => Profile(
    id: id,
    name: 'Synthetic $id',
    history: '${id.toUpperCase()}_HISTORY_MARKER',
    dateOfBirth: DateTime(2000),
  );
  ConversationSession session(String id, String profileId) =>
      ConversationSession(
        id: id,
        profileId: profileId,
        title: 'Synthetic conversation',
        createdAt: now,
        updatedAt: now,
        turns: [
          ConversationTurn(
            id: '$id-user',
            role: 'user',
            text: '${profileId.toUpperCase()}_CONVERSATION_MARKER',
            createdAt: now,
          ),
        ],
      );
  Report report(String profileId) => Report(
    id: '$profileId-report',
    profileId: profileId,
    name: '$profileId-synthetic.txt',
    extension: 'txt',
    digest: 'synthetic-$profileId',
    importedAt: now,
    eventDate: now,
    status: ReportStatus.ready,
    summaryMarkdown: '${profileId.toUpperCase()}_REPORT_MARKER',
    lines: [
      SourceLine(
        id: 'p1-l1',
        page: 1,
        text: '${profileId.toUpperCase()}_REPORT_MARKER oxygen saturation 98%.',
      ),
    ],
  );

  Future<void> configure() async {
    await c.setAllowRemoteAi(true);
    await c.setFrontierKey(FrontierModels.openAiProvider, key);
    await c.acceptFrontierDisclosure();
    await c.setFrontierChatMode(true);
    expect(c.failure, isNull);
    expect(c.frontierAvailable, isTrue);
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'ayumitra-frontier-controller-',
    );
    vault = EncryptedVault(
      directory: directory,
      key: await AesGcm.with256bits().newSecretKey(),
    );
    gateway = _Gateway();
    local = _Local();
    c = AppController(intelligence: local, frontierGateway: gateway)
      ..loaded = true
      ..vault = vault
      ..data = VaultData(
        profiles: [owner('alice'), owner('bob')],
        reports: [report('alice'), report('bob')],
        sessions: [
          session('alice-session', 'alice'),
          session('bob-session', 'bob'),
        ],
        activeProfileId: 'alice',
        activeSessionId: 'alice-session',
        activeSessionByProfile: const {
          'alice': 'alice-session',
          'bob': 'bob-session',
        },
        vitals: [
          VitalEntry(
            id: 'alice-vital',
            profileId: 'alice',
            kind: VitalKind.spo2,
            value: 98,
            unit: '%',
            measuredAt: now,
            note: 'ALICE_VITAL_MARKER',
          ),
          VitalEntry(
            id: 'bob-vital',
            profileId: 'bob',
            kind: VitalKind.spo2,
            value: 97,
            unit: '%',
            measuredAt: now,
            note: 'BOB_VITAL_MARKER',
          ),
        ],
      )
      ..activeProfileId = 'alice'
      ..activeSessionId = 'alice-session';
    c.restoreConversation();
    await vault.save(c.data);
  });
  tearDown(() async {
    c.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'saving settings, preparing context and ordinary local chat never invoke cloud',
    () async {
      await configure();
      final request = await c.prepareFrontierRequest(lookup);
      expect(request.previewText, isNotEmpty);
      expect(gateway.calls, isEmpty);
      await c.ask('Hello');
      expect(gateway.calls, isEmpty);
    },
  );

  test(
    'initializing RAM preview with a configured key causes no cloud request',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        FrontierModels.openAiKeyRef: key,
      });
      final preview = DemoController(frontierGateway: gateway);
      addTearDown(preview.dispose);
      await preview.initialize();
      expect(gateway.calls, isEmpty);
    },
  );

  test(
    'approved shared pipeline plans and answers with the cloud model while saving turns locally',
    () async {
      await configure();
      final request = await c.prepareFrontierRequest(lookup);
      expect(request.profileId, 'alice');
      expect(request.sessionId, 'alice-session');
      await c.sendFrontierRequest(request);
      expect(c.failure, isNull);
      expect(gateway.plannerCalls, hasLength(1));
      expect(gateway.answerCalls, hasLength(1));
      expect(local.calls, 0);
      final sent = gateway.answerCalls.single;
      final sentPayload = jsonDecode(sent.input) as Map;
      expect(sentPayload['question'], request.question);
      expect(
        jsonEncode(sentPayload['evidence']),
        contains('ALICE_REPORT_MARKER'),
      );
      for (final call in gateway.calls) {
        expect(call.input, isNot(contains('BOB_HISTORY_MARKER')));
        expect(call.input, isNot(contains('BOB_REPORT_MARKER')));
        expect(call.input, isNot(contains(key)));
      }
      expect(sent.apiKey, key);
      expect(sent.endpoint, Uri.parse(openAiEndpoint));
      expect(sent.provider, FrontierModels.openAiProvider);
      expect(sent.model, FrontierModels.defaultOpenAiModel);
      expect(sent.instruction, isNotEmpty);
      final saved = await vault.read();
      final turns = saved.sessions
          .firstWhere((s) => s.id == 'alice-session')
          .turns;
      expect(
        turns.any((t) => t.role == 'user' && t.text.contains(request.question)),
        isTrue,
      );
      expect(
        turns.any(
          (t) =>
              t.role == 'assistant' &&
              t.text.contains('SYNTHETIC_FRONTIER_ANSWER'),
        ),
        isTrue,
      );
      expect(jsonEncode(saved.toJson()), isNot(contains(key)));
      expect(
        jsonEncode(c.messages.map((m) => m.text).toList()),
        isNot(contains(key)),
      );
    },
  );

  test(
    'preview includes current profile context and excludes every other profile',
    () async {
      await configure();
      final request = await c.prepareFrontierRequest(
        'Summarize ALICE_REPORT_MARKER and my oxygen readings.',
      );
      expect(request.previewText, contains('ALICE_HISTORY_MARKER'));
      expect(request.previewText, contains('ALICE_CONVERSATION_MARKER'));
      expect(request.previewText, contains('ALICE_REPORT_MARKER'));
      expect(request.previewText, contains('98'));
      expect(request.previewText, isNot(contains('97%')));
      for (final marker in [
        'BOB_HISTORY_MARKER',
        'BOB_CONVERSATION_MARKER',
        'BOB_REPORT_MARKER',
        'BOB_VITAL_MARKER',
        key,
      ]) {
        expect(request.previewText, isNot(contains(marker)));
      }
      expect(gateway.calls, isEmpty);
    },
  );

  test('changing profile after preview blocks the approved request', () async {
    await configure();
    final request = await c.prepareFrontierRequest(lookup);
    await c.selectProfile('bob');
    await c.sendFrontierRequest(request);
    expect(gateway.calls, isEmpty);
    expect(c.failure, isNotNull);
  });

  test('changing session after preview blocks the approved request', () async {
    await configure();
    final request = await c.prepareFrontierRequest(lookup);
    await c.newConversation();
    await c.sendFrontierRequest(request);
    expect(gateway.calls, isEmpty);
    expect(c.failure, isNotNull);
  });

  test('changing model invalidates an earlier approval', () async {
    await configure();
    final request = await c.prepareFrontierRequest(lookup);
    await c.setFrontierModel(FrontierModels.openAiProvider, 'custom-model');
    await c.sendFrontierRequest(request);
    expect(gateway.calls, isEmpty);
    expect(c.failure, isNotNull);
  });

  test(
    'a forged nonofficial endpoint cannot receive the approved context',
    () async {
      await configure();
      final approved = await c.prepareFrontierRequest(lookup);
      final forged = FrontierRequest(
        question: approved.question,
        previewText: approved.previewText,
        profileId: approved.profileId,
        sessionId: approved.sessionId,
        provider: approved.provider,
        model: approved.model,
        endpoint: 'https://other-provider.example/v1/responses',
        revision: approved.revision,
        hits: approved.hits,
        allowedReferences: approved.allowedReferences,
      );
      await c.sendFrontierRequest(forged);
      expect(gateway.calls, isEmpty);
      expect(c.failure, isNotNull);
    },
  );

  test(
    'provider keys select official direct endpoints without gateway setup',
    () async {
      await configure();
      final openAi = await c.prepareFrontierRequest(lookup);
      expect(openAi.endpoint, openAiEndpoint);
      await c.sendFrontierRequest(openAi);
      expect(c.failure, isNull);
      expect(
        gateway.calls.every(
          (call) => call.endpoint.toString() == openAiEndpoint,
        ),
        isTrue,
      );
      await c.setFrontierKey(FrontierModels.anthropicProvider, key);
      final anthropic = await c.prepareFrontierRequest(lookup);
      expect(anthropic.provider, FrontierModels.anthropicProvider);
      expect(anthropic.model, FrontierModels.defaultClaudeModel);
      expect(anthropic.endpoint, anthropicEndpoint);
      await c.sendFrontierRequest(anthropic);
      expect(c.failure, isNull);
      expect(gateway.plannerCalls, hasLength(2));
      expect(gateway.answerCalls, hasLength(2));
      expect(gateway.calls.last.endpoint.toString(), anthropicEndpoint);
      expect(gateway.calls.last.apiKey, key);
      expect(
        await const FlutterSecureStorage().read(key: FrontierModels.gatewayRef),
        isNull,
      );
    },
  );

  test(
    'legacy prepared payload fields cannot inject another profile into the shared executor',
    () async {
      await configure();
      final approved = await c.prepareFrontierRequest(lookup);
      final poisoned = FrontierRequest(
        question: approved.question,
        previewText: 'BOB_FORGED_CONTEXT_MUST_NOT_LEAVE',
        profileId: approved.profileId,
        sessionId: approved.sessionId,
        provider: approved.provider,
        model: approved.model,
        endpoint: approved.endpoint,
        revision: approved.revision,
        hits: [],
        allowedReferences: {'bob-report/p1-l1'},
        canonicalOrder: ['bob-report/p1-l1'],
      );
      await c.sendFrontierRequest(poisoned);
      expect(c.failure, isNull);
      expect(gateway.plannerCalls, hasLength(1));
      expect(gateway.answerCalls, hasLength(1));
      expect(local.calls, 0);
      for (final call in gateway.calls) {
        expect(
          call.input,
          isNot(contains('BOB_FORGED_CONTEXT_MUST_NOT_LEAVE')),
        );
        expect(call.input, isNot(contains('BOB_REPORT_MARKER')));
      }
      expect(c.messages.last.hits, isNotEmpty);
      expect(
        c.messages.last.hits.every((hit) => hit.report.profileId == 'alice'),
        isTrue,
      );
      expect(c.messages.last.text, isNot(contains('[bob-report/p1-l1]')));
    },
  );

  test('removing provider key invalidates an earlier approval', () async {
    await configure();
    final request = await c.prepareFrontierRequest(lookup);
    await c.clearFrontierKey(FrontierModels.openAiProvider);
    await c.sendFrontierRequest(request);
    expect(gateway.calls, isEmpty);
    expect(c.failure, isNotNull);
  });

  test(
    'gateway failure makes one approved call without local fallback',
    () async {
      await configure();
      gateway.fail = true;
      final request = await c.prepareFrontierRequest(lookup);
      final before = local.calls;
      await c.sendFrontierRequest(request);
      expect(gateway.calls, hasLength(1));
      expect(local.calls, before);
      expect(c.failure, isNotNull);
      expect(
        c.messages.any((m) => m.text.contains('SYNTHETIC_FRONTIER_ANSWER')),
        isFalse,
      );
      expect('${c.failure}', isNot(contains(key)));
    },
  );

  test(
    'unknown citation is repaired without changing approved context or echoing output',
    () async {
      await configure();
      const rejected = 'DO_NOT_ECHO_REJECTED_MARKER [invented-source]';
      gateway.outputs.addAll([
        rejected,
        'SYNTHETIC_FRONTIER_ANSWER [user-history]',
      ]);
      final request = await c.prepareFrontierRequest(lookup);
      final before = local.calls;
      await c.sendFrontierRequest(request);
      expect(c.failure, isNull);
      expect(gateway.plannerCalls, hasLength(1));
      expect(gateway.answerCalls, hasLength(2));
      expect(
        gateway.answerCalls.first.instruction,
        isNot(gateway.answerCalls.last.instruction),
      );
      expect(gateway.calls.last.instruction.toLowerCase(), contains('repair'));
      final initial = jsonDecode(gateway.answerCalls.first.input) as Map;
      for (final call in gateway.answerCalls) {
        final payload = jsonDecode(call.input) as Map;
        for (final field in [
          'question',
          'evidence',
          'currentSessionUserContext',
          'userProvidedHistory',
          'userRecordedVitals',
          'citationGuide',
        ]) {
          expect(payload[field], initial[field]);
        }
        expect(call.provider, request.provider);
        expect(call.model, request.model);
        expect(call.endpoint, Uri.parse(request.endpoint));
        expect(call.apiKey, key);
        expect(call.instruction, isNot(contains(rejected)));
        expect(call.instruction, isNot(contains(key)));
      }
      expect(local.calls, before);
      final saved = await vault.read();
      final turns = saved.sessions
          .firstWhere((s) => s.id == 'alice-session')
          .turns;
      expect(turns.where((t) => t.text == request.question), hasLength(1));
      expect(turns.where((t) => t.role == 'assistant'), hasLength(1));
      expect(
        jsonEncode(saved.toJson()),
        isNot(contains('DO_NOT_ECHO_REJECTED_MARKER')),
      );
      expect(jsonEncode(saved.toJson()), isNot(contains(key)));
    },
  );

  test(
    'malformed answers stop after ten repairs without an unapproved context or fallback model',
    () async {
      await configure();
      gateway.outputs.addAll(
        List.filled(10, 'REJECTED_FORMAT_MARKER [unknown-reference]'),
      );
      final request = await c.prepareFrontierRequest(lookup);
      final before = local.calls;
      await c.sendFrontierRequest(request);
      expect(gateway.plannerCalls, hasLength(1));
      expect(gateway.answerCalls, hasLength(10));
      expect(local.calls, before);
      final initial = jsonDecode(gateway.answerCalls.first.input) as Map;
      for (final call in gateway.answerCalls) {
        final payload = jsonDecode(call.input) as Map;
        expect(payload['question'], request.question);
        expect(payload['evidence'], initial['evidence']);
        expect(call.provider, request.provider);
        expect(call.model, request.model);
        expect(call.apiKey, key);
        expect(call.instruction, isNot(contains('REJECTED_FORMAT_MARKER')));
      }
      final turns = (await vault.read()).sessions
          .firstWhere((s) => s.id == 'alice-session')
          .turns;
      expect(turns.where((t) => t.text == request.question), hasLength(1));
      final assistantTurns = turns.where((t) => t.role == 'assistant').toList();
      expect(assistantTurns, hasLength(1));
      expect(assistantTurns.single.text, contains('fallback'));
      expect(
        assistantTurns.single.text,
        isNot(contains('REJECTED_FORMAT_MARKER')),
      );
      expect(
        jsonEncode(c.data.toJson()),
        isNot(contains('REJECTED_FORMAT_MARKER')),
      );
      expect('${c.failure}', isNot(contains(key)));
    },
  );

  test('replacing a provider key invalidates an earlier approval', () async {
    await configure();
    final request = await c.prepareFrontierRequest(lookup);
    await c.setFrontierKey(
      FrontierModels.openAiProvider,
      'SYNTHETIC-REPLACEMENT-KEY',
    );
    await c.sendFrontierRequest(request);
    expect(gateway.calls, isEmpty);
    expect(c.failure, isNotNull);
  });

  test(
    'cloud disclosure is required even if chat mode is enabled in memory',
    () async {
      await c.setFrontierKey(FrontierModels.openAiProvider, key);
      expect(c.frontierDisclosureAccepted, isFalse);
      await c.setFrontierChatMode(true);
      expect(c.useFrontierForChat, isFalse);
      expect(c.failure, isNotNull);
      // Defense in depth: dispatch checks the persisted disclosure state rather
      // than trusting a composer toggle alone.
      c.useFrontierForChat = true;
      final request = await c.prepareFrontierRequest(lookup);
      await c.sendFrontierRequest(request);
      expect(gateway.calls, isEmpty);
      expect(c.failure, isNotNull);
    },
  );

  test(
    'disabling cloud chat blocks dispatch without clearing saved provider settings',
    () async {
      await configure();
      await c.setFrontierChatMode(false);
      expect(c.frontierDisclosureAccepted, isTrue);
      expect(c.useFrontierForChat, isFalse);
      expect(c.frontierKeySavedFor(FrontierModels.openAiProvider), isTrue);
      final request = await c.prepareFrontierRequest(lookup);
      await c.sendFrontierRequest(request);
      expect(gateway.calls, isEmpty);
      expect(c.failure, isNotNull);
    },
  );

  test(
    'one-time cloud disclosure and selected mode persist without sending data',
    () async {
      await configure();
      const storage = FlutterSecureStorage();
      expect(c.frontierDisclosureAccepted, isTrue);
      expect(c.useFrontierForChat, isTrue);
      expect(await storage.read(key: FrontierModels.disclosureRef), 'accepted');
      expect(await storage.read(key: FrontierModels.chatModeRef), 'cloud');
      expect(gateway.calls, isEmpty);
      await c.setFrontierChatMode(false);
      expect(await storage.read(key: FrontierModels.chatModeRef), 'local');
      expect(await storage.read(key: FrontierModels.disclosureRef), 'accepted');
      expect(c.frontierDisclosureAccepted, isTrue);
      expect(gateway.calls, isEmpty);
      final serialized = jsonEncode((await vault.read()).toJson());
      expect(serialized, isNot(contains(key)));
    },
  );

  test('settings persist in secure storage, never in the vault', () async {
    await configure();
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: FrontierModels.openAiKeyRef), key);
    expect(await storage.read(key: FrontierModels.gatewayRef), isNull);
    expect(c.frontierKeySavedFor(FrontierModels.openAiProvider), isTrue);
    expect(c.frontierKeySavedFor(FrontierModels.anthropicProvider), isFalse);
    expect(jsonEncode((await vault.read()).toJson()), isNot(contains(key)));
    await c.setFrontierModel('invalid-provider', 'synthetic-model');
    expect(c.failure, isNotNull);
    expect(await storage.read(key: FrontierModels.gatewayRef), isNull);
    expect(gateway.calls, isEmpty);
  });

  test(
    'a no-access refusal is repaired, never persisted as the answer',
    () async {
      await configure();
      gateway.outputs.addAll([
        'I don\u2019t have access to your files. [user-history]',
        'SYNTHETIC_FRONTIER_ANSWER [user-history]',
      ]);
      final request = await c.prepareFrontierRequest(lookup);
      await c.sendFrontierRequest(request);
      expect(c.failure, isNull);
      expect(gateway.plannerCalls, hasLength(1));
      expect(gateway.answerCalls, hasLength(2));
      expect(
        gateway.answerCalls.last.instruction.toLowerCase(),
        contains('repair'),
      );
      final turns = (await vault.read()).sessions
          .firstWhere((s) => s.id == 'alice-session')
          .turns;
      final answers = turns.where((t) => t.role == 'assistant').toList();
      expect(answers, hasLength(1));
      expect(answers.single.text, contains('SYNTHETIC_FRONTIER_ANSWER'));
      expect(answers.single.text, isNot(contains('have access')));
    },
  );

  test(
    'remote AI revocation during planning discards the response before tools or answer persistence',
    () async {
      await configure();
      final request = await c.prepareFrontierRequest(lookup);
      gateway.onGenerate = () {
        c.allowRemoteAi = false;
      };
      await c.sendFrontierRequest(request);
      expect(gateway.calls, hasLength(1));
      expect(gateway.answerCalls, isEmpty);
      expect(local.calls, 0);
      expect(c.failure, isNotNull);
      final turns = (await vault.read()).sessions
          .firstWhere((session) => session.id == 'alice-session')
          .turns;
      expect(turns.where((turn) => turn.role == 'assistant'), isEmpty);
    },
  );

  test('claimsNoCloudAccess matches refusals, not ordinary access words', () {
    for (final refusal in [
      'I don\u2019t have access to your files.',
      "I don't have access to your history.",
      'I cannot access your records.',
      'I do not have access.',
      'I have no access to medical files.',
      'Without access to your reports I cannot help.',
    ]) {
      expect(claimsNoCloudAccess(refusal), isTrue, reason: refusal);
    }
    for (final fine in [
      'SYNTHETIC_FRONTIER_ANSWER',
      'To access your records, open the files tab.',
      'You can access prior readings below.',
      'I don\u2019t need anything else to answer.',
    ]) {
      expect(claimsNoCloudAccess(fine), isFalse, reason: fine);
    }
  });

  test('cloud preview carries dated turns and the citation guide', () async {
    await configure();
    final request = await c.prepareFrontierRequest(lookup);
    expect(request.previewText, contains('currentSessionUserTurns'));
    expect(request.previewText, contains('providedAt'));
    expect(request.previewText, contains('citationGuide'));
    expect(request.previewText, contains('full access'));
    expect(request.canonicalOrder, contains('user-history'));
    expect(request.canonicalOrder, contains('conversation:alice-session'));
  });

  test('remote AI toggle gates cloud mode and dispatch', () async {
    await c.setFrontierKey(FrontierModels.openAiProvider, key);
    await c.acceptFrontierDisclosure();
    expect(c.allowRemoteAi, isFalse);
    await c.setFrontierChatMode(true);
    expect(c.useFrontierForChat, isFalse);
    expect(c.failure, isNotNull);
    const storage = FlutterSecureStorage();
    await c.setAllowRemoteAi(true);
    expect(c.failure, isNull);
    expect(c.allowRemoteAi, isTrue);
    expect(await storage.read(key: FrontierModels.remoteAiRef), 'enabled');
    await c.setFrontierChatMode(true);
    expect(c.useFrontierForChat, isTrue);
    final request = await c.prepareFrontierRequest(lookup);
    await c.sendFrontierRequest(request);
    expect(c.failure, isNull);
    expect(gateway.plannerCalls, hasLength(1));
    expect(gateway.answerCalls, hasLength(1));
    final completedCalls = gateway.calls.length;
    await c.setAllowRemoteAi(false);
    expect(c.allowRemoteAi, isFalse);
    expect(c.useFrontierForChat, isFalse);
    expect(await storage.read(key: FrontierModels.remoteAiRef), 'disabled');
    expect(await storage.read(key: FrontierModels.chatModeRef), 'local');
    await c.sendFrontierRequest(request);
    expect(gateway.calls, hasLength(completedCalls));
    expect(c.failure, isNotNull);
  });
}
