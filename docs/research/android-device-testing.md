# Android physical-device core testing (S24)

Debug-only synthetic harness for the true on-device core: the production
`AppController` with `LocalIntelligence` and `LocalEmbeddings`. No emulator
bridge, no host loopback, no microphone, wake-word work deferred.

## Model artifacts (Main owns download/staging)

Official public artifacts, generic bundles:

| Role | Artifact | Bytes | SHA256 | Revision |
| --- | --- | --- | --- | --- |
| Assistant | `gemma-4-E2B-it.litertlm` ([Gemma 4 E2B model card](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)) | 2588147712 | `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` | `b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1` |
| Embeddings | `embeddinggemma-2-text-270m.litertlm` ([EmbeddingGemma 2 Text model card](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm)) | 164626432 | `2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb` | `9be6e8b90982095dc05c2bd162e4b954ee4dbac7` |

Stage into the debug app’s private support directory before running. If files
were pushed to app external storage first, copy them with `adb shell run-as
app.ayumitra.ayumitra cp` into `files/ayumitra-models/`; this avoids scoped
external-storage visibility differences. Example target:

```sh
<app support files>/ayumitra-models/gemma-4-E2B-it.litertlm
<app support files>/ayumitra-models/embeddinggemma-2-text-270m.litertlm
```

The harness installs staged files through the real production setup
(`NativePickedFile` + `AppController.installModel`, fingerprint-named copy
under `local-models`). There is no downloader in the app and the harness
downloads nothing. Re-running skips install when models are already loaded.

## What the harness does

`checks/android_device_smoke.dart` (debug builds only):

1. Opens the encrypted vault and requires installed Gemma 4 + EmbeddingGemma 2.
2. Creates/selects ONLY its own marked profile (`AYUMITRA_SYNTHETIC_DEVICE_CORE_V1`,
   DOB 2020-01-15). It never clears the vault and never deletes unknown profiles.
   Fresh setup refuses a stale marked profile; `AYUMITRA_DEVICE_RESUME` instead
   reuses the existing profile and report (importing only when missing,
   validating exact file name plus expected bytes otherwise) and reruns the
   query/update checks. A `needsReview` report from an interrupted run is
   reprocessed through the existing public `retry` path; any other state is
   validated as-is — the harness invents no user-data mutations.
3. Imports one synthetic TXT (report date 2026-03-14, Hb 11.2 g/dL, WBC 7.4)
   and verifies: byte-exact encrypted original, ciphertext at rest,
   cross-profile read denial, non-empty finite vectors (dimension measured and
   reported, never assumed), validated exact 11.2 g/dL fact, category `lab`,
   clinical date 2026-03-14, Markdown summary carrying the fixture value.
4. Asks the real local model for the March 14 hemoglobin and requires 11.2 g/dL
   with citations to owned files only.
5. Sends chat update "My hemoglobin is 13 g/dL", requires conversation
   provenance plus a report request, recalls it with its provided date, and
   requires the original 11.2 report unchanged.
6. Creates a second synthetic profile and requires report/memory isolation,
   then returns to the owner profile.
7. Requires the health-bearing index to be ciphertext.
8. Prints wall-clock `INSTALL_MS` / `IMPORT_MS` / `QUERY_MS` only. No TPS claim;
   phone benchmarking is tracked separately.
9. Reports the actual inference backend via `LocalIntelligence.activeBackend`,
   read after real inference ran (setup/resume query). Restore/deletion modes
   perform no inference and may legitimately report `none-yet`. Markdown prose
   is never matched exactly; facts and references are.

Failure output is controlled check labels (`AYUMITRA_DEVICE CHECK <label>`);
raw prompts, model outputs, transcripts, keys, and vault data are never logged.

## Run order (safe install, no reinstall retry)

Each mode is baked into its own APK. Install explicitly so a failure aborts
instead of triggering an uninstall retry — an uninstall would wipe the
encrypted vault. If `install -r` fails, stop and fix storage by hand; never
uninstall an app holding saved profiles.

```sh
flutter build apk --debug --target-platform android-arm64 --target checks/android_device_smoke.dart
adb -s <device> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <device> shell am start -n app.ayumitra.ayumitra/.MainActivity
# Fresh process: verify persistence, no mutations (rebuild with the define first):
flutter build apk --debug --target-platform android-arm64 --target checks/android_device_smoke.dart --dart-define=AYUMITRA_DEVICE_RESTORE=true
adb -s <device> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <device> shell am start -n app.ayumitra.ayumitra/.MainActivity
# Continue an interrupted run on the existing marked profile/report:
flutter build apk --debug --target-platform android-arm64 --target checks/android_device_smoke.dart --dart-define=AYUMITRA_DEVICE_RESUME=true
adb -s <device> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <device> shell am start -n app.ayumitra.ayumitra/.MainActivity
# Optional separate mode: delete ONLY the harness's own synthetic conversation:
flutter build apk --debug --target-platform android-arm64 --target checks/android_device_smoke.dart --dart-define=AYUMITRA_DEVICE_DELETION=true
adb -s <device> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <device> shell am start -n app.ayumitra.ayumitra/.MainActivity
```

Look for `AYUMITRA_DEVICE ALL_PASS` in each run. The full app stays open
after the run for manual inspection when the controller is healthy.

## Safety and scope notes

- Synthetic fixture data only. Never load real patient data.
- Setup mode refuses to run when a stale marked profile already exists; use
  restore/resume/deletion modes or remove the synthetic profiles in the app.
  Resume never creates, deletes, or rewrites profiles or reports; a
  `needsReview` report is reprocessed only through the existing public
  `retry` path, and any other unexpected state fails clearly instead of
  being repaired by invented mutations.
- No microphone, no speech-asset, no wake-word code paths are touched here.
- A PASS here never claims speech, TPS, or release-performance results.

## Current validation checkpoint (13 October 2026)

The public assistant and embedding artifacts above were downloaded and their
SHA256 digests verified on both the Mac and S24. Both are staged in the debug
app's private support directory. The S24 run reached assistant setup, then
Android reported the phone dozing and the import stopped advancing. No
on-device Gemma generation, embedding, or core-flow PASS is claimed yet.
The unit suite has 276 passing tests, including native and browser report
summary repair success and native capped-repair fallback. Both controllers
keep citation validation on every attempt and never echo rejected drafts.
Wake-word work is parked: the real S24 recognizer transcribed Ayu as are you.

An additional real-model check on the Android emulator (using the explicit
Mac localhost bridge) passed current-user recall of 13 with its provided
date, and the original March 14 value of 11.2 after that update. This found
and fixed a routing defect: answer-format instructions after a question
were being classified as observations. They now remain request instructions
on both native and browser paths. Emulator results do not establish S24
on-device inference or performance.
