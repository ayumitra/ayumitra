import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/frontier_models.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/frontier_gateway.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/second_opinion_draft.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _CloudCall {
  _CloudCall(
    this.instruction,
    this.input,
    this.endpoint,
    this.provider,
    this.model,
  );
  final String instruction, input, provider, model;
  final Uri endpoint;
}

class _BlockedGateway extends FrontierGateway {
  final entered = Completer<void>();
  final release = Completer<String>();
  final calls = <_CloudCall>[];
  bool blockFirst = true;

  @override
  Future<String> generate({
    required Uri endpoint,
    required String provider,
    required String model,
    required String apiKey,
    required String instruction,
    required String input,
  }) async {
    // Deliberately do not retain or log the key in this fake.
    calls.add(_CloudCall(instruction, input, endpoint, provider, model));
    if (calls.length == 1) {
      entered.complete();
      if (blockFirst) return await release.future;
    }
    if (instruction.startsWith(plannerPrompt)) {
      return '{"actions":[{"action":"search_records","query":"synthetic"}]}';
    }
    final sourceIds = <String>{};
    void collect(dynamic value) {
      if (value is Map) {
        final id = value['sourceId'];
        if (id is String && RegExp(r'^S\d+$').hasMatch(id)) sourceIds.add(id);
        for (final child in value.values) {
          collect(child);
        }
      } else if (value is List) {
        for (final child in value) {
          collect(child);
        }
      }
    }

    collect(jsonDecode(input));
    return '## Synthetic draft\nSYNTHETIC_CLOUD_DRAFT ${sourceIds.map((id) => '[$id]').join(' ')}';
  }
}

class _UnavailableLocal extends LocalIntelligence {
  int calls = 0;
  @override
  bool get available => false;
  @override
  Future<String> generate(String instruction, String input) async {
    calls++;
    throw StateError('Synthetic local model is intentionally unavailable.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  const syntheticKey = 'SYNTHETIC-REVOCATION-KEY';
  final now = DateTime(2026, 10, 14, 10);
  late Directory directory;
  late EncryptedVault vault;
  late _BlockedGateway gateway;
  late _UnavailableLocal local;
  late AppController c;
  var disposed = false;

  Future<void> configureCloud() async {
    await c.setAllowRemoteAi(true);
    await c.setFrontierKey(FrontierModels.openAiProvider, syntheticKey);
    await c.acceptFrontierDisclosure();
    await c.setFrontierChatMode(true);
    expect(c.failure, isNull);
  }

  void releasePlanner() {
    if (gateway.release.isCompleted) return;
    gateway.release.complete(
      jsonEncode({
        'actions': [
          {
            'action': 'record_metric',
            'query': jsonEncode({
              'kind': 'weight',
              'value': 80,
              'unit': 'kg',
              'date': '2026-10-14',
            }),
          },
          {'action': 'search_records', 'query': 'synthetic'},
        ],
      }),
    );
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    disposed = false;
    directory = await Directory.systemTemp.createTemp(
      'ayumitra-cloud-revocation-',
    );
    vault = EncryptedVault(
      directory: directory,
      key: await AesGcm.with256bits().newSecretKey(),
    );
    gateway = _BlockedGateway();
    local = _UnavailableLocal();
    c =
        AppController(
            intelligence: local,
            frontierGateway: gateway,
            secureStorage: storage,
          )
          ..loaded = true
          ..vault = vault
          ..data = VaultData(
            profiles: [
              Profile(
                id: 'synthetic-owner',
                name: 'Synthetic profile',
                history: 'Synthetic user history.',
                dateOfBirth: DateTime(2000),
              ),
            ],
            sessions: [
              ConversationSession(
                id: 'synthetic-session',
                profileId: 'synthetic-owner',
                title: 'Synthetic conversation',
                createdAt: now,
                updatedAt: now,
                turns: [
                  ConversationTurn(
                    id: 'synthetic-turn',
                    role: 'user',
                    text:
                        'Please summarize my synthetic report for a clinician.',
                    createdAt: now,
                  ),
                ],
              ),
            ],
            reports: [
              Report(
                id: 'synthetic-report',
                profileId: 'synthetic-owner',
                name: 'synthetic.txt',
                extension: 'txt',
                digest: 'synthetic',
                importedAt: now,
                eventDate: now,
                status: ReportStatus.ready,
                lines: const [
                  SourceLine(
                    id: 'p1-l1',
                    page: 1,
                    text: 'Synthetic report text.',
                  ),
                ],
              ),
            ],
            activeProfileId: 'synthetic-owner',
            activeSessionId: 'synthetic-session',
            activeSessionByProfile: const {
              'synthetic-owner': 'synthetic-session',
            },
          )
          ..activeProfileId = 'synthetic-owner'
          ..activeSessionId = 'synthetic-session';
    c.restoreConversation();
    await vault.save(c.data);
    await configureCloud();
  });

  tearDown(() async {
    releasePlanner();
    if (!disposed) c.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'remote master switch revokes an active planner before any tool write or second call',
    () async {
      final request = await c.prepareFrontierRequest(
        'What does my synthetic report say?',
      );
      final work = c.sendFrontierRequest(request);
      await gateway.entered.future;
      expect(c.busy, isTrue);
      expect(gateway.calls.single.instruction, startsWith(plannerPrompt));
      try {
        await c.setAllowRemoteAi(false);
        expect(c.allowRemoteAi, isFalse);
        expect(c.useFrontierForChat, isFalse);
        expect(await storage.read(key: FrontierModels.remoteAiRef), 'disabled');
      } finally {
        releasePlanner();
        await work;
      }
      expect(gateway.calls, hasLength(1));
      expect(local.calls, 0);
      expect(c.data.vitals, isEmpty);
      expect(
        c.data.sessions.single.turns.where((t) => t.role == 'assistant'),
        isEmpty,
      );
      final saved = await vault.read();
      expect(saved.vitals, isEmpty);
      expect(
        saved.sessions.single.turns.where((t) => t.role == 'assistant'),
        isEmpty,
      );
      expect(jsonEncode(saved.toJson()), isNot(contains(syntheticKey)));
    },
  );

  test(
    'switching back to local revokes an active cloud planner without a fallback',
    () async {
      final request = await c.prepareFrontierRequest(
        'What does my synthetic report say?',
      );
      final work = c.sendFrontierRequest(request);
      await gateway.entered.future;
      try {
        await c.setFrontierChatMode(false);
        expect(c.useFrontierForChat, isFalse);
      } finally {
        releasePlanner();
        await work;
      }
      expect(gateway.calls, hasLength(1));
      expect(local.calls, 0);
      expect(c.data.vitals, isEmpty);
      expect(
        c.data.sessions.single.turns.where((t) => t.role == 'assistant'),
        isEmpty,
      );
    },
  );

  test(
    'removing the selected provider key revokes an active cloud planner',
    () async {
      final request = await c.prepareFrontierRequest(
        'What does my synthetic report say?',
      );
      final work = c.sendFrontierRequest(request);
      await gateway.entered.future;
      try {
        await c.clearFrontierKey(FrontierModels.openAiProvider);
        expect(c.frontierKeySavedFor(FrontierModels.openAiProvider), isFalse);
        expect(await storage.read(key: FrontierModels.openAiKeyRef), isNull);
      } finally {
        releasePlanner();
        await work;
      }
      expect(gateway.calls, hasLength(1));
      expect(local.calls, 0);
      expect(c.data.vitals, isEmpty);
      expect(
        c.data.sessions.single.turns.where((t) => t.role == 'assistant'),
        isEmpty,
      );
    },
  );

  test(
    'disposing the controller discards an in-flight result and prevents later cloud steps',
    () async {
      final request = await c.prepareFrontierRequest(
        'What does my synthetic report say?',
      );
      final work = c.sendFrontierRequest(request);
      await gateway.entered.future;
      c.dispose();
      disposed = true;
      releasePlanner();
      await work;
      expect(gateway.calls, hasLength(1));
      expect(local.calls, 0);
      final saved = await vault.read();
      expect(saved.vitals, isEmpty);
      expect(
        saved.sessions.single.turns.where((t) => t.role == 'assistant'),
        isEmpty,
      );
    },
  );

  test(
    'explicit draft generation uses the selected provider with no local model installed',
    () async {
      gateway.blockFirst = false;
      expect(local.available, isFalse);
      expect(c.selectedAssistantAvailable, isTrue);
      final pack = await c.generateSecondOpinionDraft();
      expect(c.failure, isNull);
      expect(pack, isNotNull);
      expect(pack!.profileId, 'synthetic-owner');
      expect(pack.sessionId, 'synthetic-session');
      expect(pack.markdown, contains('SYNTHETIC_CLOUD_DRAFT'));
      expect(gateway.calls, hasLength(1));
      expect(
        gateway.calls.single.instruction,
        startsWith(secondOpinionDraftPrompt),
      );
      expect(
        gateway.calls.single.endpoint,
        FrontierGateway.providerEndpoint('openai'),
      );
      expect(gateway.calls.single.provider, 'openai');
      expect(gateway.calls.single.model, FrontierModels.defaultOpenAiModel);
      expect(local.calls, 0);
      expect(jsonEncode(c.data.toJson()), isNot(contains(syntheticKey)));
    },
  );
}
