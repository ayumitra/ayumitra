import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app_controller.dart';
import 'ui/app.dart';
import 'services/notice_registry.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerAyumitraNotices();
  // Avoid health-bearing exception text reaching the ordinary Flutter log.
  FlutterError.onError = (details) {
    debugPrint('Ayumitra UI error: ${details.exception.runtimeType}');
  };
  final controller = AppController();
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
