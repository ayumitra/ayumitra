import 'dart:async';

import 'package:ayumitra/services/app_lock.dart';
import 'package:ayumitra/ui/app_lock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLock extends ChangeNotifier implements AppLockController {
  @override
  bool initialized = true;
  @override
  bool enabled = true;
  @override
  bool locked = true;
  @override
  bool busy = false;
  @override
  bool needsReload = false;
  @override
  AppLockMode mode = AppLockMode.pin;
  @override
  String? error;
  @override
  Duration cooldownRemaining = Duration.zero;
  @override
  Duration get remainingCooldown => cooldownRemaining;
  final submittedPins = <String>[];
  int initializationCalls = 0, backgroundLocks = 0, deviceCalls = 0;
  int _epoch = 0;
  Completer<bool>? deviceResult;

  void changed() => notifyListeners();
  @override
  Future<void> initialize() async {
    initializationCalls++;
    initialized = true;
    mode = AppLockMode.pin;
    needsReload = false;
    error = null;
    notifyListeners();
  }

  @override
  void lock() {
    _epoch++;
    backgroundLocks++;
    locked = !initialized || enabled;
    notifyListeners();
  }

  @override
  void lockForBackground() => lock();
  @override
  Future<bool> unlockWithPin(String pin) async {
    submittedPins.add(pin);
    final success = pin == '246810';
    locked = !success;
    error = success ? null : 'That PIN did not match.';
    notifyListeners();
    return success;
  }

  @override
  Future<bool> unlockWithDevice() async {
    final epoch = _epoch;
    deviceCalls++;
    busy = true;
    notifyListeners();
    final success = await (deviceResult?.future ?? Future.value(true));
    busy = false;
    if (epoch == _epoch && success) locked = false;
    notifyListeners();
    return epoch == _epoch && success;
  }

  @override
  Future<bool> configurePin(String pin) async => false;
  @override
  Future<bool> configureDevice() async => false;
  @override
  Future<bool> disable() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RetainedChild extends StatefulWidget {
  const _RetainedChild({super.key});
  @override
  State<_RetainedChild> createState() => _RetainedChildState();
}

class _RetainedChildState extends State<_RetainedChild> {
  int counter = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('private-action'),
        onPressed: () => setState(() => counter++),
        child: Text('SYNTHETIC_PRIVATE_CONTENT $counter'),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.ayumitra/app_lock');
  final privacyCalls = <MethodCall>[];
  setUp(() {
    privacyCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          privacyCalls.add(call);
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<GlobalKey<_RetainedChildState>> mount(
    WidgetTester tester,
    _FakeLock lock, {
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final childKey = GlobalKey<_RetainedChildState>();
    await tester.pumpWidget(
      AppLockGate(
        controller: lock,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: _RetainedChild(key: childKey),
        ),
      ),
    );
    await tester.pump();
    return childKey;
  }

  testWidgets(
    'startup loading covers a retained child and disabled lock opens normally',
    (tester) async {
      final lock = _FakeLock()
        ..initialized = false
        ..enabled = false
        ..mode = AppLockMode.off;
      addTearDown(lock.dispose);
      final key = await mount(tester, lock);
      final retained = key.currentState;
      expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('app-lock-pin')), findsNothing);
      expect(lock.initializationCalls, 0);
      final semantics = tester.widget<ExcludeSemantics>(
        find.byType(ExcludeSemantics).first,
      );
      expect(semantics.excluding, isTrue);
      lock
        ..initialized = true
        ..locked = false;
      lock.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
      expect(key.currentState, same(retained));
      await tester.tap(find.byKey(const ValueKey('private-action')));
      await tester.pump();
      expect(key.currentState!.counter, 1);
    },
  );

  testWidgets(
    'PIN entry is obscured, reports failure, and unlocks without remounting the app',
    (tester) async {
      final lock = _FakeLock();
      addTearDown(lock.dispose);
      final key = await mount(tester, lock);
      final retained = key.currentState;
      final input = find.byKey(const ValueKey('app-lock-pin'));
      expect(tester.widget<TextField>(input).obscureText, isTrue);
      await tester.enterText(input, '000000');
      await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await tester.pumpAndSettle();
      expect(lock.locked, isTrue);
      expect(find.text('That PIN did not match.'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.enterText(input, '246810');
      await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await tester.pumpAndSettle();
      expect(lock.submittedPins, ['000000', '246810']);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
      expect(key.currentState, same(retained));
    },
  );

  testWidgets(
    'cooldown disables attempts until the controller allows another',
    (tester) async {
      final lock = _FakeLock()..cooldownRemaining = const Duration(seconds: 5);
      addTearDown(lock.dispose);
      await mount(tester, lock);
      expect(find.text('Try again in 5 seconds.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('app-lock-unlock')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('app-lock-pin')))
            .enabled,
        isFalse,
      );
      lock.cooldownRemaining = Duration.zero;
      lock.changed();
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('app-lock-unlock')))
            .onPressed,
        isNotNull,
      );
      expect(lock.submittedPins, isEmpty);
    },
  );

  testWidgets(
    'failed configuration load remains opaque and offers a nondestructive retry',
    (tester) async {
      final lock = _FakeLock()
        ..mode = AppLockMode.off
        ..needsReload = true
        ..error = 'App lock settings could not be read safely.';
      addTearDown(lock.dispose);
      await mount(tester, lock);
      expect(find.byKey(const ValueKey('app-lock-pin')), findsNothing);
      expect(find.byKey(const ValueKey('app-lock-device')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('app-lock-retry')));
      await tester.pumpAndSettle();
      expect(lock.initializationCalls, 1);
      expect(lock.locked, isTrue);
      expect(find.byKey(const ValueKey('app-lock-pin')), findsOneWidget);
    },
  );

  testWidgets(
    'a failed secure write hides retained PIN authentication until settings are reloaded',
    (tester) async {
      final lock = _FakeLock()
        ..mode = AppLockMode.pin
        ..needsReload = true
        ..error = 'App lock settings could not be saved safely.';
      addTearDown(lock.dispose);
      await mount(tester, lock);
      expect(find.byKey(const ValueKey('app-lock-pin')), findsNothing);
      expect(find.byKey(const ValueKey('app-lock-unlock')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('app-lock-retry')));
      await tester.pumpAndSettle();
      expect(lock.initializationCalls, 1);
      expect(lock.needsReload, isFalse);
      expect(lock.locked, isTrue);
      expect(find.byKey(const ValueKey('app-lock-pin')), findsOneWidget);
    },
  );

  testWidgets(
    'temporary inactive shields immediately without forcing a new lock',
    (tester) async {
      final lock = _FakeLock()..locked = false;
      addTearDown(lock.dispose);
      final key = await mount(tester, lock);
      final retained = key.currentState;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);
      expect(lock.backgroundLocks, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
      expect(lock.locked, isFalse);
      expect(key.currentState, same(retained));
      expect(
        privacyCalls.any(
          (call) =>
              call.method == 'setPrivacyVisible' &&
              (call.arguments as Map)['visible'] == true,
        ),
        isTrue,
      );
      expect(privacyCalls.last.method, 'setPrivacyVisible');
      expect((privacyCalls.last.arguments as Map)['visible'], isFalse);
    },
  );

  testWidgets(
    'backgrounding locks and resume never exposes a nested private route or permits back to pop it',
    (tester) async {
      final lock = _FakeLock()..locked = false;
      addTearDown(lock.dispose);
      final navigator = GlobalKey<NavigatorState>();
      final key = await mount(tester, lock, navigatorKey: navigator);
      final retained = key.currentState;
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Text('SYNTHETIC_PRIVATE_FILE')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(navigator.currentState!.canPop(), isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(lock.backgroundLocks, greaterThan(0));
      expect(lock.locked, isTrue);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(navigator.currentState!.canPop(), isTrue);
      expect(key.currentState, same(retained));
      lock.locked = false;
      lock.changed();
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC_PRIVATE_FILE'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
    },
  );

  testWidgets(
    'device authentication is explicit and an inactive dialog does not invalidate it',
    (tester) async {
      final lock = _FakeLock()
        ..mode = AppLockMode.device
        ..deviceResult = Completer<bool>();
      addTearDown(lock.dispose);
      await mount(tester, lock);
      expect(lock.deviceCalls, 0);
      await tester.tap(find.byKey(const ValueKey('app-lock-device')));
      await tester.pump();
      expect(lock.deviceCalls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(lock.backgroundLocks, 0);
      lock.deviceResult!.complete(true);
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(lock.locked, isFalse);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
    },
  );

  testWidgets(
    'late device authentication cannot uncover a real background lock',
    (tester) async {
      final lock = _FakeLock()
        ..mode = AppLockMode.device
        ..deviceResult = Completer<bool>();
      addTearDown(lock.dispose);
      await mount(tester, lock);
      await tester.tap(find.byKey(const ValueKey('app-lock-device')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      lock.deviceResult!.complete(true);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(lock.locked, isTrue);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);
    },
  );
}
