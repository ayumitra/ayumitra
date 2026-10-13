import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/emulator/emulator_controller.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('emulator bridge refuses non-debug builds', () {
    expect(() => requireEmulatorDebugBuild(false), throwsUnsupportedError);
    requireEmulatorDebugBuild(true);
  });

  test(
    'native development controller starts unverified with fixed loopback and configured local roles',
    () {
      var requests = 0;
      final controller = EmulatorAppController(
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 500);
        }),
        chatModel: 'synthetic-local-chat',
        visionModel: 'synthetic-local-vision',
        embeddingModel: 'synthetic-local-embedding',
      );
      addTearDown(controller.dispose);
      expect(controller.isPreview, false);
      final intelligence = controller.intelligence as WebIntelligence;
      final embeddings = controller.embeddings as WebEmbeddings;
      expect(intelligence.endpoint, emulatorLocalEndpoint);
      expect(embeddings.endpoint, emulatorLocalEndpoint);
      expect(intelligence.chatModel, 'synthetic-local-chat');
      expect(intelligence.visionModel, 'synthetic-local-vision');
      expect(embeddings.embeddingModel, 'synthetic-local-embedding');
      expect(intelligence.available, false);
      expect(intelligence.visionAvailable, false);
      expect(embeddings.available, false);
      expect(requests, 0);
    },
  );

  test(
    'unavailable computer models leave encrypted native profiles and conversations durable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ayumitra-emulator-vault-',
      );
      final key = await AesGcm.with256bits().newSecretKey();
      final vault = EncryptedVault(directory: directory, key: key);
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 500);
      });
      final first = EmulatorAppController(client: client)
        ..vault = vault
        ..loaded = true;
      final second = EmulatorAppController(client: client);
      addTearDown(() async {
        first.dispose();
        second.dispose();
        await directory.delete(recursive: true);
      });
      await first.createProfile(
        'Synthetic Emulator Person',
        DateTime(2000),
        '',
        false,
      );
      await first.ask('SYNTHETIC_DURABLE_EMULATOR_TURN');
      expect(first.messages.last.text, contains('local assistant model'));
      final saved = await vault.read();
      final originalSession = first.activeSessionId;
      second.vault = EncryptedVault(directory: directory, key: key);
      second.data = await second.vault.read();
      second.activeProfileId = saved.activeProfileId;
      second.activeSessionId = originalSession;
      second.loaded = true;
      second.restoreConversation();
      expect(second.profile!.name, 'Synthetic Emulator Person');
      expect(
        second.activeSession!.turns.first.text,
        'SYNTHETIC_DURABLE_EMULATOR_TURN',
      );
      expect(second.messages.first.text, 'SYNTHETIC_DURABLE_EMULATOR_TURN');
      expect(requests, 0);
      final raw = latin1.decode(
        await File('${directory.path}/index.enc').readAsBytes(),
      );
      expect(raw.contains('SYNTHETIC_DURABLE_EMULATOR_TURN'), false);
      expect(raw.contains('Synthetic Emulator Person'), false);
    },
  );
}
