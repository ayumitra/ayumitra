import 'package:ayumitra/services/app_lock.dart';
import 'package:ayumitra/ui/security_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Lock extends AppLockController {
  AppLockMode current = AppLockMode.off;
  bool covered = false;
  String? configuredPin;
  int deviceRequests = 0, locks = 0, disables = 0;
  @override
  bool get initialized => true;
  @override
  bool get enabled => current != AppLockMode.off;
  @override
  bool get locked => covered;
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  AppLockMode get mode => current;
  @override
  void lock() {
    locks++;
    covered = true;
    notifyListeners();
  }

  @override
  Future<bool> configurePin(String pin) async {
    configuredPin = pin;
    current = AppLockMode.pin;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> configureDevice() async {
    deviceRequests++;
    current = AppLockMode.device;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> disable() async {
    disables++;
    current = AppLockMode.off;
    notifyListeners();
    return true;
  }

  void authenticate() {
    covered = false;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'PIN confirmation rejects mismatch and enables only a matching PIN',
    (tester) async {
      final lock = _Lock();
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        MaterialApp(home: SecuritySettingsScreen(controller: lock)),
      );
      await tester.tap(find.byKey(const Key('security-set-pin')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('security-new-pin')),
        '123456',
      );
      await tester.enterText(
        find.byKey(const Key('security-confirm-pin')),
        '654321',
      );
      await tester.tap(find.byKey(const Key('security-save-pin')));
      await tester.pumpAndSettle();
      expect(find.text('The PINs do not match.'), findsOneWidget);
      expect(lock.configuredPin, isNull);
      await tester.enterText(
        find.byKey(const Key('security-confirm-pin')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('security-save-pin')));
      await tester.pumpAndSettle();
      expect(lock.configuredPin, '123456');
      expect(lock.mode, AppLockMode.pin);
      expect(find.text('App lock · App PIN'), findsOneWidget);
    },
  );

  testWidgets(
    'changing or disabling an existing lock waits for authentication',
    (tester) async {
      final lock = _Lock()..current = AppLockMode.pin;
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        MaterialApp(home: SecuritySettingsScreen(controller: lock)),
      );
      await tester.tap(find.byKey(const Key('security-use-device')));
      await tester.pump();
      expect(lock.locks, 1);
      expect(lock.deviceRequests, 0);
      lock.authenticate();
      await tester.pumpAndSettle();
      expect(lock.deviceRequests, 1);
      await tester.ensureVisible(find.byKey(const Key('security-disable')));
      await tester.tap(find.byKey(const Key('security-disable')));
      await tester.pump();
      expect(lock.locks, 2);
      expect(lock.disables, 0);
      lock.authenticate();
      await tester.pumpAndSettle();
      expect(lock.disables, 1);
      expect(lock.enabled, isFalse);
    },
  );
}
