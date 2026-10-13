import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app_controller.dart';
import 'services/notice_registry.dart';
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
  runApp(AyumitraApp(controller: controller));
  unawaited(() async {
    try {
      await pdfrxFlutterInitialize();
      await controller.initialize();
    } catch (_) {
      controller.initializationFailed();
    }
  }());
}
