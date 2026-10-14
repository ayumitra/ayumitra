// Debug Android entrypoint: normal app startup with non-secret restore checks.
//
// Uses the production controller, web-search implementation, vault, model
// setup, and UI. It does not replace the search client, read key values, create
// synthetic profiles, submit questions, or invoke inference/provider APIs.
// Normal production background recovery remains enabled.
//
// Install with `adb install -r`; never uninstall to repair an install failure.
// This diagnostic is not a production entrypoint or a paid-provider test.
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/app_startup.dart';
import 'package:ayumitra/services/automatic_models.dart';

class _RestoreCheckController extends AppController {
  bool _reportedSetup = false;

  @override
  Future<void> initialize() async {
    try {
      await super.initialize();
      debugPrint(
        'AYUMITRA_SETTINGS restore_pass=true '
        'search_configured=${webSearch.available} '
        'cloud_disclosed=$frontierDisclosureAccepted '
        'cloud_selected=$useFrontierForChat',
      );
    } catch (_) {
      debugPrint('AYUMITRA_SETTINGS restore_pass=false');
      rethrow;
    }
  }

  @override
  Future<void> ensureAutomaticModels({AutomaticModels? setup}) async {
    try {
      await super.ensureAutomaticModels(setup: setup);
      if (_reportedSetup) return;
      _reportedSetup = true;
      debugPrint(
        'AYUMITRA_SETTINGS setup_checked=true '
        'local_model_ready=${intelligence.available} '
        'embeddings_ready=${embeddings.available}',
      );
    } catch (_) {
      if (!_reportedSetup) {
        _reportedSetup = true;
        debugPrint('AYUMITRA_SETTINGS setup_checked=false');
      }
      rethrow;
    }
  }
}

Future<void> main() async {
  if (!kDebugMode || kIsWeb || !Platform.isAndroid) {
    throw UnsupportedError('This diagnostic requires debug Android.');
  }
  await launchAyumitraController(_RestoreCheckController());
}
