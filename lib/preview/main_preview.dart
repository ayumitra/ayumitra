import 'package:flutter/material.dart';

import '../ui/app.dart';
import '../services/notice_registry.dart';
import '../services/web_llm.dart';
import 'demo_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAyumitraNotices();
  final controller = DemoController(
    intelligence: WebIntelligence(),
    embeddings: WebEmbeddings(),
  );
  await controller.initialize();
  runApp(AyumitraApp(controller: controller));
}
