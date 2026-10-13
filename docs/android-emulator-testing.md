# Android emulator testing: two modes

Two ways to run AyuMitra on Android. They differ in where inference runs and
what is stored where. The default production entrypoint is unchanged.

## Mode 1 — production: on-device LiteRT weights (default)

- Entrypoint: `lib/main.dart` (unchanged default).
- Inference: on-device model files picked in Companion settings
  (assistant + EmbeddingGemma 2), installed with `installModel`.
- Storage: encrypted native vault on the device; originals sealed per
  profile at `originals/<profileId>/<reportId>.enc`, readable only when the
  report's profile is active.
- No network for inference. Public web info is a separately gated native
  tool; the browser client has it disabled.

## Mode 2 — debug only: host localhost models via emulator bridge

For development on an emulator with real Gemma 4 + EmbeddingGemma 2 calls,
while testing native file storage and the assistant interface. Report content is processed by the local host computer in this development mode.

- Entrypoint: `flutter run -t lib/main_emulator.dart` (**debug builds only**).
  Release/profile builds render a refusal screen instead of a bridge
  (`kDebugMode` guard in `main_emulator.dart`, re-checked in the
  `EmulatorAppController` factory, so no release override is possible).
- Inference: models run **on the Mac**, reached from the emulator through
  `adb reverse tcp:11434 tcp:11434`. Fixed loopback endpoint
  `http://127.0.0.1:11434`; the strict loopback-only client is reused, so
  there is no cloud path and no cloud fallback.
- Settings shows the local-server UI with the explicit development label:
  testing only, not on-device inference, documents stay encrypted on
  Android. File-weight picking is disabled in this mode.
- Storage: the ordinary native encrypted vault — records persist across
  emulator restarts exactly like production.

### Host setup

1. Install the official local Ollama model on the Mac (this GGUF artifact is for the host server; the mobile app imports separate LiteRT model files):
   `ollama pull gemma4:e2b-it-q4_K_M`
   Install the embedding model separately: `ollama pull embeddinggemma-2`.
2. Never substitute a cloud/proxy tag. `connect()` verifies each role via
   local metadata (`/api/tags`, `/api/show`); unknown, remote, or missing
   models fail closed (`available == false`) with keyword search remaining.
   Optional compile-time overrides:
   `AYUMITRA_LOCAL_CHAT_MODEL`, `AYUMITRA_LOCAL_VISION_MODEL`,
   `AYUMITRA_LOCAL_EMBEDDING_MODEL`.
3. Start the local server, confirm installed models with `ollama list` and `ollama show <tag>`, then reverse the port for the connected emulator:
   `adb reverse tcp:11434 tcp:11434`.
4. The debug manifest allows plain HTTP only for literal loopback hosts. Other HTTP destinations remain refused. The release manifest retains its cleartext restriction. The model client separately refuses external endpoints, redirects and remote model metadata.

## Data and claims

- Synthetic fixture/test data only. Never load real patient data into
  either mode.
- No Samsung S24 performance claim follows from emulator runs: host model timings are not phone performance measurements. Phone benchmarking
  needs a connected handset and is tracked separately.
- `checks/android_emulator_smoke.dart` runs the native controller, secure storage and PDF parser on Android against real local models. It creates only labelled synthetic profiles and imports TXT/PDF fixtures, checks original bytes and ciphertext, validates embedding vectors and cited answers, then checks profile isolation. It does not automate the Android file-picker UI.

```sh
adb reverse tcp:11434 tcp:11434
flutter run --no-pub -d emulator-5554 -t checks/android_emulator_smoke.dart
# Quit the first run, then restart the process and verify persisted data:
flutter run --no-pub -d emulator-5554 -t checks/android_emulator_smoke.dart --dart-define=AYUMITRA_SMOKE_RESTORE=true
# To verify immediate chat updates and query the on-device speech capability:
flutter run --no-pub -d emulator-5554 -t checks/android_emulator_smoke.dart --dart-define=AYUMITRA_SMOKE_MEMORY=true
# For normal manual development testing:
flutter run --no-pub -d emulator-5554 -t lib/main_emulator.dart
```

Look for `AYUMITRA_SMOKE ALL_PASS` in each run. The check leaves its synthetic profiles and encrypted files available for manual inspection; it never wipes the emulator or removes other profiles.

## Chat-memory runtime check

After creating the synthetic smoke profile above, verify an immediately saved
user observation and then its restoration in a fresh process:

```sh
flutter run -d emulator-5554 -t checks/android_emulator_smoke.dart --dart-define=AYUMITRA_SMOKE_MEMORY=true
# Quit that run, then start a fresh process:
flutter run -d emulator-5554 -t checks/android_emulator_smoke.dart --dart-define=AYUMITRA_SMOKE_MEMORY_RESTORE=true
```

The check uses synthetic hemoglobin 13 g/dL, verifies conversation provenance
and its provided date, and preserves the original March report's 11.2 g/dL.
It checks voice capability without requesting microphone access; this does
not prove microphone transcription or wake activation on a physical phone.

## Updating without discarding emulator data

A low-storage install failure can lead to the existing app being removed.
Use an explicit update where any install failure aborts instead:

```sh
flutter build apk --debug --target-platform android-arm64 --target lib/main_emulator.dart
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
```

If the manual `install -r` fails, stop and fix storage first; never
uninstall an app containing saved profiles to recover space — an uninstall
wipes its encrypted vault.

Launch the app through the Android developer tool after the update succeeds:

```sh
adb -s emulator-5554 shell am start -n app.ayumitra.ayumitra/.MainActivity
```

Pushing the APK checksum or passing `--use-application-binary` does not
skip Flutter's install step: `AndroidDevice.startApp` runs `installApp`
in Flutter 3.44. A later `flutter run` can therefore attempt another update
and its uninstall retry after a failed installation. Use the explicit SDK
update and launch above when preserving saved emulator profiles.
