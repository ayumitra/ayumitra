import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app_controller.dart';
import 'services/notice_registry.dart';
import 'services/app_lock.dart';
import 'ui/app_lock_screen.dart';
import 'ui/app.dart';

/// Native startup shared by development entrypoints. Mirrors main.dart's
/// English dates, local PDF initialization, notices and health-safe errors.
Future<void> launchAyumitraController(AppController controller) async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'en_US';
  await initializeDateFormatting('en_US');
  registerAyumitraNotices();
  FlutterError.onError = (details) {
    debugPrint('Ayumitra UI error: ${details.exception.runtimeType}');
  };
  final appLock = controller.appLock ?? AppLockController();
  controller.appLock = appLock;
  runApp(
    AppLockGate(
      controller: appLock,
      child: AyumitraApp(controller: controller),
    ),
  );
  unawaited(() async {
    try {
      await appLock.initialize();
      if (!appLock.initialized || appLock.locked) {
        final unlocked = Completer<void>();
        void changed() {
          if (appLock.initialized && !appLock.locked && !unlocked.isCompleted) {
            unlocked.complete();
          }
        }

        appLock.addListener(changed);
        changed();
        try {
          await unlocked.future;
        } finally {
          appLock.removeListener(changed);
        }
      }
      await pdfrxFlutterInitialize();
      await controller.initialize();
      unawaited(controller.ensureAutomaticModels());
    } catch (_) {
      controller.initializationFailed();
    }
  }());
}
