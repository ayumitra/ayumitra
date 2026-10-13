import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_controller.dart';
import '../services/web_llm.dart';

const emulatorLocalEndpoint = 'http://127.0.0.1:11434';
const emulatorChatModel = String.fromEnvironment(
  'AYUMITRA_LOCAL_CHAT_MODEL',
  defaultValue: 'gemma4:e2b-it-q4_K_M',
);
const emulatorVisionModel = String.fromEnvironment(
  'AYUMITRA_LOCAL_VISION_MODEL',
  defaultValue: emulatorChatModel,
);
const emulatorEmbeddingModel = String.fromEnvironment(
  'AYUMITRA_LOCAL_EMBEDDING_MODEL',
  defaultValue: 'embeddinggemma-2:latest',
);

void requireEmulatorDebugBuild(bool isDebugBuild) {
  if (!isDebugBuild) {
    throw UnsupportedError('The emulator local-server bridge is debug-only.');
  }
}

/// Native development mode: encrypted profiles, originals, conversation
/// history and vectors live in the emulator's ordinary native vault.
/// Inference runs on the developer's computer through adb reverse, not in
/// the emulator. The verified loopback-only client never uses cloud inference.
class EmulatorAppController extends AppController {
  factory EmulatorAppController({
    http.Client? client,
    bool automaticProcessingChecks = true,
    String chatModel = emulatorChatModel,
    String visionModel = emulatorVisionModel,
    String embeddingModel = emulatorEmbeddingModel,
  }) {
    // No caller-controlled release override: the factory always checks the
    // actual build mode, including accidental imports from another entrypoint.
    requireEmulatorDebugBuild(kDebugMode);
    return EmulatorAppController._(
      automaticProcessingChecks: automaticProcessingChecks,
      intelligence: WebIntelligence(client: client)
        ..endpoint = emulatorLocalEndpoint
        ..chatModel = chatModel
        ..visionModel = visionModel,
      embeddings: WebEmbeddings(client: client)
        ..endpoint = emulatorLocalEndpoint
        ..embeddingModel = embeddingModel,
    );
  }

  EmulatorAppController._({
    required this.automaticProcessingChecks,
    required WebIntelligence intelligence,
    required WebEmbeddings embeddings,
  }) : super(intelligence: intelligence, embeddings: embeddings);

  final bool automaticProcessingChecks;
  @override
  bool get automaticProcessingChecksEnabled =>
      automaticProcessingChecks && super.automaticProcessingChecksEnabled;

  @override
  Future<void> initialize() async {
    // The encrypted vault is opened independently of model availability.
    await super.initialize();
    if (!loaded) return;
    announceStep('Development mode · verifying models on this computer…');
    var failed = false;
    try {
      await (intelligence as WebIntelligence).connect();
    } catch (_) {
      failed = true;
    }
    try {
      await (embeddings as WebEmbeddings).connect();
    } catch (_) {
      failed = true;
    }
    if (failed) {
      failure =
          'Your encrypted emulator records are available. The computer’s local models could not be verified. Check local AI setup and adb reverse; no cloud fallback was used.';
    } else {
      failure = null;
    }
    activity = '';
    refreshViews();
  }
}
