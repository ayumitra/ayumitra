import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/frontier_models.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FailingProfileSaveVault extends EncryptedVault {
  _FailingProfileSaveVault({required super.directory, required super.key});

  @override
  Future<void> save(VaultData data) async {
    throw const FileSystemException('Synthetic profile persistence failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const braveRef = 'ayumitra-web-search-key';
  const braveKey = 'SYNTHETIC_BRAVE_KEY';
  const openAiKey = 'SYNTHETIC_OPENAI_KEY';
  const anthropicKey = 'SYNTHETIC_ANTHROPIC_KEY';
  const storage = FlutterSecureStorage();
  late Directory directory;
  late AppController c;
  late WebSearch search;
  late MockClient httpClient;
  var failTransport = false;
  var statusCode = 503;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    failTransport = false;
    statusCode = 503;
    directory = await Directory.systemTemp.createTemp('ayumitra-brave-key-');
    httpClient = MockClient((request) async {
      if (failTransport) {
        throw const SocketException('Synthetic offline device');
      }
      return http.Response('', statusCode);
    });
    search = WebSearch(client: httpClient);
    c = AppController(webSearch: search)
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
            history: '',
            dateOfBirth: DateTime(2001),
          ),
        ],
      )
      ..vault = EncryptedVault(
        directory: directory,
        key: await AesGcm.with256bits().newSecretKey(),
      );
    await c.vault.save(c.data);
    await c.setWebKey('  $braveKey  ');
    expect(c.failure, isNull);
  });

  tearDown(() async {
    c.dispose();
    httpClient.close();
    await directory.delete(recursive: true);
  });

  Future<void> expectBraveRetained() async {
    expect(search.available, isTrue);
    expect(search.apiKey, braveKey);
    expect(await storage.read(key: braveRef), braveKey);
    final serialized = jsonEncode((await c.vault.read()).toJson());
    expect(serialized, isNot(contains(braveKey)));
    expect('${c.failure}', isNot(contains(braveKey)));
    expect(
      jsonEncode(c.messages.map((message) => message.text).toList()),
      isNot(contains(braveKey)),
    );
  }

  test(
    'search key is trimmed and readable from a fresh secure-storage handle',
    () async {
      expect(search.apiKey, braveKey);
      expect(await const FlutterSecureStorage().read(key: braveRef), braveKey);
      // This checks durable credential storage without pretending to initialize
      // Android's model/filesystem runtime in a host unit test.
      final other = AppController(webSearch: WebSearch(client: httpClient));
      addTearDown(other.dispose);
      expect(await const FlutterSecureStorage().read(key: braveRef), braveKey);
      await expectBraveRetained();
    },
  );

  test('blank replacement keeps the existing Brave credential', () async {
    await c.setWebKey('   ');
    expect(c.failure, contains('kept'));
    await expectBraveRetained();
  });

  test(
    'provider keys, selected cloud mode and provider changes never clear search settings',
    () async {
      await c.setAllowRemoteAi(true);
      await c.setFrontierKey(FrontierModels.openAiProvider, openAiKey);
      await c.acceptFrontierDisclosure();
      await c.setFrontierChatMode(true);
      await expectBraveRetained();
      await c.setFrontierKey(FrontierModels.anthropicProvider, anthropicKey);
      await c.setFrontierModel(
        FrontierModels.anthropicProvider,
        FrontierModels.defaultClaudeModel,
      );
      await expectBraveRetained();
      await c.setFrontierChatMode(false);
      await c.clearFrontierKey(FrontierModels.openAiProvider);
      await c.clearFrontierKey(FrontierModels.anthropicProvider);
      await expectBraveRetained();
      expect(await storage.read(key: FrontierModels.openAiKeyRef), isNull);
      expect(await storage.read(key: FrontierModels.anthropicKeyRef), isNull);
      expect(await storage.read(key: FrontierModels.chatModeRef), 'local');
    },
  );

  test(
    'rejected provider settings leave the unrelated search credential intact',
    () async {
      await c.setFrontierKey(FrontierModels.openAiProvider, openAiKey);
      await c.setFrontierKey(FrontierModels.openAiProvider, ' ');
      expect(c.failure, isNotNull);
      await expectBraveRetained();
      await c.setFrontierModel('invalid-provider', 'synthetic-model');
      expect(c.failure, isNotNull);
      await expectBraveRetained();
      expect(await storage.read(key: FrontierModels.openAiKeyRef), openAiKey);
    },
  );

  test(
    'profile switching and profile deletion preserve global search settings',
    () async {
      await c.selectProfile('bob');
      await expectBraveRetained();
      await c.selectProfile('alice');
      await c.deleteProfile('alice');
      expect(c.failure, isNull);
      expect(c.data.profiles.map((profile) => profile.id), ['bob']);
      await expectBraveRetained();
    },
  );

  test(
    'a failed profile deletion preserves both the profile and Brave credential',
    () async {
      c.vault = _FailingProfileSaveVault(
        directory: c.vault.directory,
        key: c.vault.key,
      );
      await c.deleteProfile('alice');
      expect(c.failure, isNotNull);
      expect(c.data.profiles.map((profile) => profile.id), ['alice', 'bob']);
      await expectBraveRetained();
    },
  );

  test(
    'search transport failure does not remove or invalidate the stored key',
    () async {
      failTransport = true;
      await expectLater(
        search.search('oxygen saturation explanation'),
        throwsA(isA<SocketException>()),
      );
      await expectBraveRetained();
    },
  );

  test(
    'temporary and authorization HTTP failures never silently delete the key',
    () async {
      for (final code in [503, 429, 403, 401]) {
        statusCode = code;
        await expectLater(
          search.search('oxygen saturation explanation'),
          throwsA(isA<StateError>()),
        );
        await expectBraveRetained();
      }
    },
  );
}
