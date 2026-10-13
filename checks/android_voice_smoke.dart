// Manual native speech check. Synthetic speech only; no transcripts are logged.
// Run on an Android emulator after an explicit development mic grant:
// adb shell pm grant app.ayumitra.ayumitra android.permission.RECORD_AUDIO
// flutter run -d emulator-5554 -t checks/android_voice_smoke.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ayumitra/services/local_voice.dart';

Future<void> main() async {
  if (!kDebugMode) throw UnsupportedError('Voice smoke is debug-only.');
  WidgetsFlutterBinding.ensureInitialized();
  final completion = Completer<void>();
  final voice = LocalVoice(
    onCommand: (command) {
      if (command.toLowerCase().trim() == 'show my reports') {
        debugPrint(
          'AYUMITRA_VOICE PASS synthetic wake dispatched exact command',
        );
        if (!completion.isCompleted) completion.complete();
      } else {
        debugPrint('AYUMITRA_VOICE command mismatch (text withheld)');
      }
    },
  );
  var lastFailure = '';
  voice.addListener(() {
    if (voice.failure.isNotEmpty && voice.failure != lastFailure) {
      lastFailure = voice.failure;
      // Service-generated controlled error, never recognized text.
      debugPrint('AYUMITRA_VOICE unavailable: ${voice.failure}');
    }
  });
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: AnimatedBuilder(
            animation: voice,
            builder: (_, _) => Text(
              'Synthetic Android voice test\n'
              '${voice.status}\n${voice.failure}\n'
              'Say: Hey aa-yuh-mit-ra, show my reports',
            ),
          ),
        ),
      ),
    ),
  );
  await voice.setWakeEnabled(true);
  debugPrint(
    'AYUMITRA_VOICE native start available=${voice.available} listening=${voice.listening}',
  );
  try {
    await completion.future.timeout(const Duration(seconds: 90));
    debugPrint('AYUMITRA_VOICE ALL_PASS');
  } on TimeoutException {
    debugPrint('AYUMITRA_VOICE no verified wake command within test window');
  } finally {
    await voice.stop();
  }
}
