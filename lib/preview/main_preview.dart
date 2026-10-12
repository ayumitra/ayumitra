import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../ui/app.dart';
import '../services/notice_registry.dart';
import '../services/web_llm.dart';
import 'demo_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // pdfrx declares these assets for web builds. Pin its client, worker and
  // PDFium WASM to this app's own asset directory rather than a remote host.
  Pdfrx.pdfiumWasmModulesUrl = Uri.base
      .resolve('assets/packages/pdfrx/assets/')
      .toString();
  Pdfrx.pdfiumWasmWithCredentials = false;
  await pdfrxFlutterInitialize();
  registerAyumitraNotices();
  final controller = DemoController(
    intelligence: WebIntelligence(),
    embeddings: WebEmbeddings(),
  );
  await controller.initialize();
  runApp(AyumitraApp(controller: controller));
}
