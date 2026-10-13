import 'package:ayumitra/app_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic credentials only; never device storage or an actual API key.
class _DiscardingStorage extends FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'saving a key persists beyond the controller and restores via storage',
    () async {
      final controller = AppController();
      await controller.setWebKey('  synthetic-search-key  ');
      expect(controller.failure, isNull);
      expect(controller.webSearch.available, isTrue);
      controller.dispose();
      final restored = await const FlutterSecureStorage().read(
        key: 'ayumitra-web-search-key',
      );
      expect(restored, 'synthetic-search-key');
    },
  );

  test('an empty replacement preserves the saved credential', () async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.setWebKey('synthetic-existing-key');
    await controller.setWebKey(' \n ');
    expect(controller.webSearch.apiKey, 'synthetic-existing-key');
    expect(
      await const FlutterSecureStorage().read(key: 'ayumitra-web-search-key'),
      'synthetic-existing-key',
    );
    expect(controller.failure, contains('has been kept'));
  });

  test('a storage write that did not persist cannot report success', () async {
    final controller = AppController(secureStorage: _DiscardingStorage());
    addTearDown(controller.dispose);
    await controller.setWebKey('synthetic-new-key');
    expect(controller.failure, isNotNull);
    expect(controller.webSearch.available, isFalse);
    expect(
      await const FlutterSecureStorage().read(key: 'ayumitra-web-search-key'),
      isNull,
    );
  });
}
