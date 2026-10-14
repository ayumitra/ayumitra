import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

enum AppLockMode { off, pin, device }

typedef PinDerivation = Future<List<int>> Function(String pin, List<int> salt);

/// Optional local UI access gate. It does not replace vault encryption, erase
/// data, sync credentials, or recover/reset a forgotten PIN. No automatic prompt.
class AppLockController extends ChangeNotifier {
  AppLockController({
    FlutterSecureStorage? secureStorage,
    LocalAuthentication? authentication,
    DateTime Function()? now,
    PinDerivation? derivePin,
    List<int> Function(int length)? randomBytes,
  }) : _storage =
           secureStorage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(resetOnError: false),
           ),
       _authentication = authentication ?? LocalAuthentication(),
       _now = now ?? DateTime.now,
       _derivePin = derivePin ?? _pbkdf2,
       _randomBytes = randomBytes ?? _secureBytes;

  static const storageKey = 'ayumitra-app-lock-v1';
  static const pinIterations = 600000;
  static const _storageError =
      'App lock settings could not be read or saved safely. Access stays locked. Retry loading the settings; your records have not been removed.';
  final FlutterSecureStorage _storage;
  final LocalAuthentication _authentication;
  final DateTime Function() _now;
  final PinDerivation _derivePin;
  final List<int> Function(int length) _randomBytes;
  _LockConfig _config = const _LockConfig(AppLockMode.off);
  bool _initialized = false, _locked = true, _busy = false;
  bool _storageFailure = false, _disposed = false;
  int _epoch = 0;
  String? _error;

  bool get initialized => _initialized;
  bool get enabled => _storageFailure || mode != AppLockMode.off;
  bool get locked => _locked;
  AppLockMode get mode => _config.mode;
  bool get busy => _busy;
  bool get needsReload => _storageFailure;
  String? get error => _error;
  Duration get cooldownRemaining {
    final until = _config.cooldownUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(_now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Duration get remainingCooldown => cooldownRemaining;

  static Future<List<int>> _pbkdf2(String pin, List<int> salt) async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: pinIterations,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return await key.extractBytes();
  }

  static List<int> _secureBytes(int length) {
    final random = Random.secure();
    return List.generate(length, (_) => random.nextInt(256));
  }

  static bool _validPin(String pin) => RegExp(r'^[0-9]{6,12}$').hasMatch(pin);
  static bool _equalHash(List<int> actual, List<int> expected) {
    if (expected.length != 32) return false;
    var difference = actual.length ^ expected.length;
    for (var i = 0; i < 32; i++) {
      difference |= (i < actual.length ? actual[i] : 0) ^ expected[i];
    }
    return difference == 0;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _failStorage() {
    _storageFailure = true;
    _locked = true;
    _error = _storageError;
  }

  Future<void> initialize() async {
    if (_disposed || _busy) return;
    _busy = true;
    _locked = true;
    final epoch = ++_epoch;
    _notify();
    try {
      final raw = await _storage.read(key: storageKey);
      final next = raw == null
          ? const _LockConfig(AppLockMode.off)
          : _LockConfig.decode(raw);
      if (_disposed) return;
      _config = next;
      _storageFailure = false;
      _error = null;
      _initialized = true;
      _locked = next.mode != AppLockMode.off;
      // A load is never an authentication, including when backgrounded mid-read.
      if (epoch != _epoch && enabled) _locked = true;
    } catch (_) {
      if (!_disposed) {
        _initialized = true;
        _failStorage();
      }
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// UI calls this after genuine backgrounding; an inactive biometric dialog
  /// only needs an opaque privacy shield, not another lock() call.
  void lock() {
    if (_disposed) return;
    _epoch++;
    _locked = !_initialized || enabled;
    if (!_storageFailure) _error = null;
    unawaited(
      _authentication.stopAuthentication().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    _notify();
  }

  void lockForBackground() => lock();

  bool _canStart({bool needsUnlocked = false}) {
    if (_disposed || _busy) return false;
    if (!_initialized || _storageFailure) {
      _locked = true;
      _error = _storageError;
      _notify();
      return false;
    }
    if (needsUnlocked && _locked) {
      _error = 'Unlock Ayumitra before changing app lock settings.';
      _notify();
      return false;
    }
    return true;
  }

  Future<bool> _persist(
    _LockConfig next, {
    required bool unlock,
    required int epoch,
  }) async {
    final encoded = next.encode();
    final previous = _config;
    try {
      await _storage.write(key: storageKey, value: encoded);
      final saved = await _storage.read(key: storageKey);
      if (saved != encoded) throw StateError('Lock readback failed.');
      // Disabling must not turn a backgrounded/closed session into an unlocked
      // one. Restore the previous credential if lifecycle revocation raced I/O.
      if (next.mode == AppLockMode.off &&
          previous.mode != AppLockMode.off &&
          epoch != _epoch) {
        final restore = previous.encode();
        await _storage.write(key: storageKey, value: restore);
        if (await _storage.read(key: storageKey) != restore) {
          throw StateError('Lock rollback readback failed.');
        }
        if (!_disposed) {
          _config = previous;
          _locked = true;
          _error =
              'The app was backgrounded before lock settings changed. Unlock and try again.';
        }
        return false;
      }
      if (_disposed) return false;
      _config = next;
      _storageFailure = false;
      _locked = next.mode != AppLockMode.off && (!unlock || epoch != _epoch);
      return epoch == _epoch;
    } catch (_) {
      if (!_disposed) _failStorage();
      return false;
    }
  }

  Future<bool> configurePin(String pin) async {
    if (!_canStart(needsUnlocked: true)) return false;
    if (!_validPin(pin)) {
      _error = 'Choose a PIN containing 6 to 12 digits.';
      _notify();
      return false;
    }
    _busy = true;
    _error = null;
    final epoch = _epoch;
    _notify();
    try {
      final salt = _randomBytes(32);
      if (salt.length != 32 || salt.any((b) => b < 0 || b > 255)) {
        throw StateError('Invalid salt.');
      }
      final hash = await _derivePin(pin, List.unmodifiable(salt));
      if (hash.length != 32 || hash.any((b) => b < 0 || b > 255)) {
        throw StateError('Invalid hash.');
      }
      if (_disposed || epoch != _epoch || _locked) return false;
      return await _persist(
        _LockConfig(
          AppLockMode.pin,
          salt: List.unmodifiable(salt),
          hash: List.unmodifiable(hash),
        ),
        unlock: true,
        epoch: epoch,
      );
    } catch (_) {
      if (!_disposed) {
        _error =
            'The PIN could not be configured. Your previous lock settings are kept.';
      }
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<bool> _devicePrompt() => _authentication.authenticate(
    localizedReason: 'Unlock your private Ayumitra health history',
    biometricOnly: false,
    sensitiveTransaction: true,
    persistAcrossBackgrounding: false,
  );

  Future<bool> configureDevice() async {
    if (!_canStart(needsUnlocked: true)) return false;
    _busy = true;
    _error = null;
    final epoch = _epoch;
    _notify();
    try {
      if (!await _authentication.isDeviceSupported() ||
          !await _devicePrompt()) {
        if (!_disposed && epoch == _epoch) {
          _error =
              'Device authentication was not completed. Your previous lock settings are kept.';
        }
        return false;
      }
      if (_disposed || epoch != _epoch || _locked) return false;
      return await _persist(
        const _LockConfig(AppLockMode.device),
        unlock: true,
        epoch: epoch,
      );
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        _error =
            'Device authentication is unavailable. Set up a device passcode or use an app PIN.';
      }
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<bool> disable() async {
    if (!_canStart(needsUnlocked: true)) return false;
    _busy = true;
    _error = null;
    final epoch = _epoch;
    _notify();
    try {
      return await _persist(
        const _LockConfig(AppLockMode.off),
        unlock: true,
        epoch: epoch,
      );
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<bool> unlockWithPin(String pin) async {
    if (!_canStart() || mode != AppLockMode.pin) return false;
    if (!_locked) return true;
    if (cooldownRemaining > Duration.zero) {
      _error = 'Too many PIN attempts. Wait before trying again.';
      _notify();
      return false;
    }
    _busy = true;
    _error = null;
    final epoch = _epoch;
    _notify();
    try {
      // Reserve the attempt durably BEFORE expensive verification, so killing
      // the app during derivation does not reset brute-force accounting.
      final attempts = _config.failedAttempts + 1;
      final minutes = attempts < 5
          ? 0
          : attempts >= 9
          ? 15
          : 1 << (attempts - 5);
      final reserved = _config.withAttempts(
        attempts,
        minutes == 0 ? null : _now().toUtc().add(Duration(minutes: minutes)),
      );
      if (!await _persist(reserved, unlock: false, epoch: epoch)) return false;
      final actual = _validPin(pin)
          ? await _derivePin(pin, _config.salt!)
          : const <int>[];
      if (_disposed || epoch != _epoch) return false;
      if (!_equalHash(actual, _config.hash!)) {
        _error = cooldownRemaining > Duration.zero
            ? 'Too many PIN attempts. Wait before trying again.'
            : 'That PIN did not match.';
        return false;
      }
      return await _persist(
        _config.withAttempts(0, null),
        unlock: true,
        epoch: epoch,
      );
    } catch (_) {
      if (!_disposed && epoch == _epoch && !_storageFailure) {
        _error = 'The PIN could not be checked. Please retry.';
      }
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<bool> unlockWithDevice() async {
    if (!_canStart() || mode != AppLockMode.device) return false;
    if (!_locked) return true;
    _busy = true;
    _error = null;
    final epoch = _epoch;
    _notify();
    try {
      final success = await _devicePrompt();
      if (_disposed || epoch != _epoch) return false;
      if (success) {
        _locked = false;
        return true;
      }
      _error =
          'Authentication was cancelled or did not match. Your history stays locked.';
      return false;
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        _error =
            'Device authentication could not finish. Your history stays locked; please retry.';
      }
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _locked = true;
    unawaited(
      _authentication.stopAuthentication().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    super.dispose();
  }
}

class _LockConfig {
  const _LockConfig(
    this.mode, {
    this.salt,
    this.hash,
    this.failedAttempts = 0,
    this.cooldownUntil,
  });
  final AppLockMode mode;
  final List<int>? salt, hash;
  final int failedAttempts;
  final DateTime? cooldownUntil;
  _LockConfig withAttempts(int attempts, DateTime? until) => _LockConfig(
    mode,
    salt: salt,
    hash: hash,
    failedAttempts: attempts,
    cooldownUntil: until,
  );
  String encode() => jsonEncode({
    'version': 1,
    'mode': mode.name,
    'failedAttempts': failedAttempts,
    'cooldownUntil': cooldownUntil?.toUtc().toIso8601String(),
    if (mode == AppLockMode.pin) ...{
      'salt': base64Encode(salt!),
      'hash': base64Encode(hash!),
      'iterations': AppLockController.pinIterations,
    },
  });
  factory _LockConfig.decode(String encoded) {
    final map = jsonDecode(encoded);
    if (map is! Map || map['version'] != 1 || map['mode'] is! String) {
      throw const FormatException('Invalid lock.');
    }
    final mode = AppLockMode.values.byName(map['mode'] as String);
    final allowed = {
      'version',
      'mode',
      'failedAttempts',
      'cooldownUntil',
      if (mode == AppLockMode.pin) ...['salt', 'hash', 'iterations'],
    };
    if (map.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Invalid lock.');
    }
    final attempts = map['failedAttempts'];
    if (attempts is! int || attempts < 0 || attempts > 1000000) {
      throw const FormatException('Invalid lock.');
    }
    final until = map['cooldownUntil'];
    if (until != null && until is! String) {
      throw const FormatException('Invalid lock.');
    }
    final cooldown = until == null
        ? null
        : DateTime.parse(until as String).toUtc();
    if ((attempts < 5 && cooldown != null) ||
        (attempts >= 5 && cooldown == null)) {
      throw const FormatException('Invalid lock.');
    }
    if (mode != AppLockMode.pin && (attempts != 0 || cooldown != null)) {
      throw const FormatException('Invalid lock.');
    }
    if (mode != AppLockMode.pin) return _LockConfig(mode);
    if (map['iterations'] != AppLockController.pinIterations ||
        map['salt'] is! String ||
        map['hash'] is! String) {
      throw const FormatException('Invalid lock.');
    }
    final salt = base64Decode(map['salt'] as String),
        hash = base64Decode(map['hash'] as String);
    if (salt.length != 32 || hash.length != 32) {
      throw const FormatException('Invalid lock.');
    }
    return _LockConfig(
      mode,
      salt: List.unmodifiable(salt),
      hash: List.unmodifiable(hash),
      failedAttempts: attempts,
      cooldownUntil: cooldown,
    );
  }
}
