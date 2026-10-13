import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'app_startup.dart';
import 'emulator/emulator_controller.dart';

/// Launch only for debug emulator development after configuring
/// adb reverse tcp:11434 tcp:11434. Release/profile builds cannot create a bridge.
Future<void> main() async {
  if (!kDebugMode) {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'The emulator local-server entrypoint is available only in debug builds. Use the normal app entrypoint for release.',
            ),
          ),
        ),
      ),
    );
    return;
  }
  await launchAyumitraController(EmulatorAppController());
}
