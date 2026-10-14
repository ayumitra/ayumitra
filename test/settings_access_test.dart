import 'dart:async';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/app_lock.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Android automatic setup exposes app-wide lock at phone width, even during work',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lock = AppLockController();
      final c = AppController(appLock: lock)
        ..loaded = true
        ..activeProfileId = 'synthetic'
        ..data = const VaultData(
          profiles: [Profile(id: 'synthetic', name: 'Synthetic', history: '')],
        );
      addTearDown(c.dispose);
      addTearDown(lock.dispose);
      expect(c.automaticModelsSupported, isTrue);
      await tester.pumpWidget(AyumitraApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Settings'), findsOneWidget);
      final pending = Completer<void>();
      final task = c.runCancellableTask(
        'Synthetic blocked model',
        () => c.taskCall(() => pending.future),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('header-settings')));
      await tester.pumpAndSettle();
      final security = find.byKey(const Key('security-settings'));
      expect(security.hitTestable(), findsOneWidget);
      expect(find.text('App lock · all profiles'), findsOneWidget);
      expect(find.byKey(const Key('global-stop-task')), findsOneWidget);
      await tester.tap(find.byKey(const Key('global-stop-task')));
      await task;
      await tester.pumpAndSettle();
      expect(c.busy, isFalse);
      await tester.tap(security);
      await tester.pumpAndSettle();
      expect(find.text('Security and privacy'), findsOneWidget);
      expect(find.textContaining('Protect every profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
      pending.complete();
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
