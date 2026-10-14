import 'dart:async';
import 'dart:convert';

import 'package:ayumitra/services/app_lock.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

class _Storage extends FlutterSecureStorage {
  final values = <String, String>{};
  bool failRead = false, failWrite = false, dropWrites = false;
  final writes = <String>[];
  void Function()? onWrite;
  Completer<void>? pauseWrite, writeEntered;
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failRead) throw StateError('Synthetic sensitive read error.');
    return values[key];
  }

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
  }) async {
    if (failWrite) throw StateError('Synthetic sensitive write error.');
    if (!dropWrites) {
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
    }
    writes.add(value ?? '');
    if (pauseWrite != null) {
      final gate = pauseWrite!;
      pauseWrite = null;
      writeEntered?.complete();
      await gate.future;
    }
    onWrite?.call();
  }
}

class _Authentication extends LocalAuthentication {
  bool supported = true, result = true, fail = false;
  Completer<bool>? pending;
  Completer<void>? entered;
  final prompts = <Map<String, Object>>[];
  int stops = 0;
  @override
  Future<bool> isDeviceSupported() async => supported;
  @override
  Future<bool> stopAuthentication() async {
    stops++;
    return true;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    prompts.add({
      'reason': localizedReason,
      'biometricOnly': biometricOnly,
      'sensitiveTransaction': sensitiveTransaction,
      'persistAcrossBackgrounding': persistAcrossBackgrounding,
    });
    entered?.complete();
    if (fail) throw StateError('Synthetic sensitive auth error.');
    return pending == null ? result : await pending!.future;
  }
}

void main() {
  const pin = '654321';
  late _Storage storage;
  late _Authentication authentication;
  late DateTime time;
  var salts = 0;
  var derivations = 0;
  Completer<List<int>>? pendingDerivation;
  final controllers = <AppLockController>[];

  Future<List<int>> derive(String value, List<int> salt) async {
    derivations++;
    if (pendingDerivation != null) return await pendingDerivation!.future;
    // Fast deterministic test double, never used by the production controller.
    return (await Sha256().hash(
      utf8.encode('$value:${base64Encode(salt)}'),
    )).bytes;
  }

  AppLockController create() {
    final c = AppLockController(
      secureStorage: storage,
      authentication: authentication,
      now: () => time,
      derivePin: derive,
      randomBytes: (length) => List.filled(length, ++salts),
    );
    controllers.add(c);
    return c;
  }

  Map<String, dynamic> saved() => Map<String, dynamic>.from(
    jsonDecode(storage.values[AppLockController.storageKey]!) as Map,
  );

  setUp(() {
    storage = _Storage();
    authentication = _Authentication();
    time = DateTime.utc(2026, 10, 14, 12);
    salts = 0;
    derivations = 0;
    pendingDerivation = null;
  });
  tearDown(() {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
  });

  test(
    'app lock is off by default and initialization never prompts or writes',
    () async {
      final c = create();
      expect(c.initialized, isFalse);
      expect(c.locked, isTrue);
      await c.initialize();
      expect(c.initialized, isTrue);
      expect(c.enabled, isFalse);
      expect(c.mode, AppLockMode.off);
      expect(c.locked, isFalse);
      expect(storage.writes, isEmpty);
      expect(authentication.prompts, isEmpty);
      expect(AppLockController.pinIterations, 600000);
    },
  );

  test(
    'PIN format requires six to twelve digits without altering lock settings',
    () async {
      final c = create();
      await c.initialize();
      for (final value in [
        '12345',
        '1234567890123',
        'abc123',
        '123 456',
        '',
        '１２３４５６',
      ]) {
        expect(await c.configurePin(value), isFalse);
        expect(c.error, isNotNull);
        expect(c.enabled, isFalse);
      }
      expect(storage.writes, isEmpty);
      expect(derivations, 0);
    },
  );

  test(
    'PIN stores only salted derived credentials in one read-back config',
    () async {
      final c = create();
      await c.initialize();
      expect(await c.configurePin(pin), isTrue);
      expect(c.mode, AppLockMode.pin);
      expect(c.enabled, isTrue);
      expect(c.locked, isFalse);
      expect(storage.values.keys, [AppLockController.storageKey]);
      final config = saved();
      expect(config['iterations'], 600000);
      expect(base64Decode(config['salt'] as String), hasLength(32));
      expect(base64Decode(config['hash'] as String), hasLength(32));
      expect(jsonEncode(config), isNot(contains(pin)));
      expect(config.containsKey('pin'), isFalse);
      final reopened = create();
      await reopened.initialize();
      expect(reopened.locked, isTrue);
      expect(await reopened.unlockWithPin(pin), isTrue);
      expect(reopened.locked, isFalse);
      expect(saved()['failedAttempts'], 0);
      expect(saved()['cooldownUntil'], isNull);
    },
  );

  test(
    'settings cannot be changed until the current lock is unlocked',
    () async {
      final c = create();
      await c.initialize();
      await c.configurePin(pin);
      c.lock();
      final oldConfig = storage.values[AppLockController.storageKey];
      expect(await c.configurePin('123456'), isFalse);
      expect(await c.configureDevice(), isFalse);
      expect(await c.disable(), isFalse);
      expect(storage.values[AppLockController.storageKey], oldConfig);
      expect(authentication.prompts, isEmpty);
      expect(await c.unlockWithPin(pin), isTrue);
      expect(await c.configurePin('123456'), isTrue);
      expect(salts, 2);
      c.lock();
      expect(await c.unlockWithPin(pin), isFalse);
      expect(await c.unlockWithPin('123456'), isTrue);
      expect(await c.disable(), isTrue);
      expect(c.mode, AppLockMode.off);
      expect(saved().containsKey('salt'), isFalse);
      expect(saved().containsKey('hash'), isFalse);
    },
  );

  test(
    'wrong PIN throttle persists across restart and escalates to fifteen minutes',
    () async {
      final c = create();
      await c.initialize();
      await c.configurePin(pin);
      c.lock();
      for (var i = 0; i < 5; i++) {
        expect(await c.unlockWithPin('111111'), isFalse);
      }
      expect(c.cooldownRemaining, const Duration(minutes: 1));
      expect(saved()['failedAttempts'], 5);
      final reopened = create();
      await reopened.initialize();
      final before = derivations;
      expect(await reopened.unlockWithPin(pin), isFalse);
      expect(derivations, before);
      expect(reopened.cooldownRemaining, const Duration(minutes: 1));
      for (final minutes in [2, 4, 8, 15, 15]) {
        time = time.add(
          reopened.cooldownRemaining + const Duration(seconds: 1),
        );
        expect(await reopened.unlockWithPin('111111'), isFalse);
        expect(reopened.cooldownRemaining, Duration(minutes: minutes));
      }
      time = time.add(reopened.cooldownRemaining + const Duration(seconds: 1));
      expect(await reopened.unlockWithPin(pin), isTrue);
      expect(reopened.cooldownRemaining, Duration.zero);
      expect(saved()['failedAttempts'], 0);
    },
  );

  test(
    'an attempt is durable before PIN derivation and late success cannot unlock after backgrounding',
    () async {
      final c = create();
      await c.initialize();
      await c.configurePin(pin);
      c.lock();
      final hash = base64Decode(saved()['hash'] as String);
      final written = Completer<void>();
      storage.onWrite = () {
        if (!written.isCompleted) written.complete();
      };
      pendingDerivation = Completer<List<int>>();
      final unlock = c.unlockWithPin(pin);
      await written.future;
      expect(saved()['failedAttempts'], 1);
      c.lockForBackground();
      pendingDerivation!.complete(hash);
      expect(await unlock, isFalse);
      expect(c.locked, isTrue);
      final reopened = create();
      await reopened.initialize();
      expect(reopened.locked, isTrue);
      expect(saved()['failedAttempts'], 1);
    },
  );

  test(
    'corrupt and unreadable secure settings fail closed without deleting anything',
    () async {
      storage.values[AppLockController.storageKey] = '{bad json';
      final c = create();
      await c.initialize();
      expect(c.initialized, isTrue);
      expect(c.enabled, isTrue);
      expect(c.locked, isTrue);
      expect(c.error, contains('Retry'));
      expect(c.needsReload, isTrue);
      expect(await c.disable(), isFalse);
      expect(storage.values[AppLockController.storageKey], '{bad json');
      expect(storage.writes, isEmpty);
      storage.failRead = true;
      await c.initialize();
      expect(c.locked, isTrue);
      expect(c.error, isNot(contains('sensitive')));
    },
  );

  test(
    'wrong KDF configuration or truncated credentials fail closed',
    () async {
      final c = create();
      await c.initialize();
      await c.configurePin(pin);
      final valid = saved();
      for (final changed in [
        {...valid, 'iterations': 1},
        {
          ...valid,
          'hash': base64Encode([1, 2]),
        },
        {...valid, 'salt': null},
        {...valid, 'failedAttempts': -1},
        {...valid, 'mode': 'unexpected'},
        {...valid, 'failedAttempts': 5, 'cooldownUntil': null},
      ]) {
        storage.values[AppLockController.storageKey] = jsonEncode(changed);
        final invalid = create();
        await invalid.initialize();
        expect(invalid.enabled, isTrue);
        expect(invalid.locked, isTrue);
        expect(await invalid.unlockWithPin(pin), isFalse);
      }
    },
  );

  test(
    'failed config writes/readback never disable an existing lock',
    () async {
      final c = create();
      await c.initialize();
      await c.configurePin(pin);
      final original = storage.values[AppLockController.storageKey];
      storage.dropWrites = true;
      expect(await c.disable(), isFalse);
      expect(c.enabled, isTrue);
      expect(c.locked, isTrue);
      expect(storage.values[AppLockController.storageKey], original);
      storage.dropWrites = false;
      await c.initialize();
      expect(c.mode, AppLockMode.pin);
      expect(c.locked, isTrue);
      expect(c.needsReload, isFalse);
      expect(await c.unlockWithPin(pin), isTrue);
      storage.failWrite = true;
      expect(await c.configurePin('123456'), isFalse);
      expect(c.locked, isTrue);
      expect(c.error, isNot(contains('sensitive')));
      expect(storage.values[AppLockController.storageKey], original);
    },
  );

  test(
    'backgrounding during disable restores the previous credential and stays locked',
    () async {
      final c = create();
      await c.initialize();
      await c.configurePin(pin);
      final original = storage.values[AppLockController.storageKey];
      final gate = Completer<void>();
      storage.pauseWrite = gate;
      storage.writeEntered = Completer<void>();
      final disabling = c.disable();
      await storage.writeEntered!.future;
      c.lockForBackground();
      gate.complete();
      expect(await disabling, isFalse);
      expect(c.locked, isTrue);
      expect(c.mode, AppLockMode.pin);
      expect(storage.values[AppLockController.storageKey], original);
      final reopened = create();
      await reopened.initialize();
      expect(reopened.locked, isTrue);
      expect(await reopened.unlockWithPin(pin), isTrue);
    },
  );

  test(
    'device setup and unlock use local credentials with safe prompt options',
    () async {
      final c = create();
      await c.initialize();
      expect(await c.configureDevice(), isTrue);
      expect(c.mode, AppLockMode.device);
      expect(c.locked, isFalse);
      c.lock();
      authentication.result = false;
      expect(await c.unlockWithDevice(), isFalse);
      expect(c.locked, isTrue);
      authentication.result = true;
      expect(await c.unlockWithDevice(), isTrue);
      expect(c.locked, isFalse);
      for (final prompt in authentication.prompts) {
        expect(prompt['reason'], isNotEmpty);
        expect(prompt['biometricOnly'], isFalse);
        expect(prompt['sensitiveTransaction'], isTrue);
        expect(prompt['persistAcrossBackgrounding'], isFalse);
      }
      expect(saved()['mode'], 'device');
      expect(saved().containsKey('hash'), isFalse);
    },
  );

  test(
    'unsupported or failed device authentication does not weaken existing settings',
    () async {
      final c = create();
      await c.initialize();
      authentication.supported = false;
      expect(await c.configureDevice(), isFalse);
      expect(c.enabled, isFalse);
      expect(storage.writes, isEmpty);
      authentication.supported = true;
      await c.configureDevice();
      c.lock();
      authentication.fail = true;
      expect(await c.unlockWithDevice(), isFalse);
      expect(c.locked, isTrue);
      expect(c.error, isNot(contains('sensitive')));
    },
  );

  test(
    'a device prompt returning success after backgrounding keeps the app locked',
    () async {
      final c = create();
      await c.initialize();
      await c.configureDevice();
      c.lock();
      authentication.pending = Completer<bool>();
      authentication.entered = Completer<void>();
      final unlock = c.unlockWithDevice();
      await authentication.entered!.future;
      c.lockForBackground();
      authentication.pending!.complete(true);
      expect(await unlock, isFalse);
      expect(c.locked, isTrue);
      expect(authentication.stops, greaterThanOrEqualTo(2));
    },
  );

  test(
    'disposed controllers cannot accept a late successful device prompt',
    () async {
      final c = create();
      await c.initialize();
      await c.configureDevice();
      c.lock();
      authentication.pending = Completer<bool>();
      authentication.entered = Completer<void>();
      final unlock = c.unlockWithDevice();
      await authentication.entered!.future;
      controllers.remove(c);
      c.dispose();
      authentication.pending!.complete(true);
      expect(await unlock, isFalse);
      expect(c.locked, isTrue);
    },
  );
}
