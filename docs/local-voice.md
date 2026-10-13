# Local voice input

Tap the microphone to speak a command, or enable **Hey Ayumitra** while the companion screen is open. Pronounce the name **aa-yuh-mit-ra**: *ayu* (age) and *mitra* (friend). Say “Hey Ayumitra, show my reports,” or say the wake phrase first and then your command. Final recognized speech follows the normal chat path and is saved as a user turn in that profile’s encrypted conversation.

Voice input is explicit-tap, foreground-only, English-only, and strictly
on-device. There is no cloud fallback, no network audio, no model download,
no audio storage, and no background or always-on hotword service.

## Channel contract (both platforms)

- MethodChannel `app.ayumitra/voice`:
  - `capabilities` → `{available, onDevice, platform, reason?}`. `onDevice`
    is true whenever `available` is true: this bridge has no server mode.
    `reason` is present only when unavailable, and always truthful.
  - `requestPermission` → bool. Requests the microphone (plus speech
    recognition on iOS) and completes with the grant result. A second call
    while one is in flight fails with `PERMISSION_PENDING`. Dart calls this
    only after an explicit user start/wake toggle — never automatically.
  - `start {sessionId: int}` → void. Begins one session bound to that id;
    a missing/non-int id fails the method with `BAD_SESSION_ID` and starts
    nothing. Precondition failures arrive as `error` events carrying the
    requested id, never as silent no-ops.
  - `stop` → void. Ends the live session and emits `stopped` exactly once.
    Stopping an idle bridge succeeds with no event.
- EventChannel `app.ayumitra/voice_events` emits
  `{type: partial|final|error|stopped, sessionId: int, text?, code?, reason?}`.
  Android accepts the full 64-bit Dart session identifier without narrowing it. Every session event echoes the `start` call's id, captured per session —
  native never re-reads a mutable id when a queued callback runs, and keeps
  its independent generation guards. Dart strictly rejects events whose id
  does not match the live session (profile, conversation, route, or app
  change). Transcripts never appear in
  logs — lifecycle and error logs carry codes only.

## Android (`LocalVoiceBridge.kt`)

- Requires API 31+: `isOnDeviceRecognitionAvailable` gate plus
  `createOnDeviceSpeechRecognizer` only. `createSpeechRecognizer` is never
  used. Below API 31, `capabilities` reports unavailable with the reason.
- English (`EXTRA_LANGUAGE`) with `EXTRA_PREFER_OFFLINE`; on API 33+,
  `checkRecognitionSupport` must additionally confirm installed on-device
  English (`installedOnDeviceLanguages`) before listening, otherwise the
  session fails closed with `LANGUAGE_UNAVAILABLE`. Listening uses an actually installed English locale: device-default English first, then en-US, then another installed English locale. An installed en-IN pack never causes an uninstalled en-US pack to be selected. Below API 33, en-US is the default. There is no non-English or server fallback.
- On Android 13+, recognition receives local phrase-biasing hints for “Hey Ayumitra” and “Hey Ayu Mitra.” The matcher accepts narrowly spelled aa-yuh variants and word/hyphen boundaries, requires the whole name at the beginning, and ignores generic “hey you” or names merely mentioned in other speech.
- `RECORD_AUDIO` manifest entry plus a `RecognitionService` package-visibility
  query. Runtime permission is requested only from `requestPermission`;
  `start` without it emits `PERMISSION_REQUIRED`.
- `MainActivity` forwards permission results and stops the session on
  pause/destroy, releasing the microphone.

## iOS (`LocalVoiceBridge.swift`)

- English `SFSpeechRecognizer(locale: en-US)`; `start` requires
  `supportsOnDeviceRecognition` and already-granted mic/speech
  authorization. Every request sets `requiresOnDeviceRecognition = true`,
  always — server recognition is never used.
- `AVAudioEngine` feeds ephemeral buffers; no audio files are written.
- `AppDelegate` registers the bridge and stops the session on
  resign-active/terminate. `Info.plist` carries the mic/speech usage
  strings; the manual `.pbxproj` includes the new source file.

## Scope and limits

- Wake listening pauses while the assistant is busy, on another screen, or in the background. Switching profiles or conversations stops the microphone and rejects late events from the prior session. Silent sessions restart with bounded backoff.
- Audio is not saved; recognized commands are stored as encrypted chat text. Browser voice is disabled because this client has no verified on-device speech backend.
- Availability is device-dependent: Android needs an installed
  on-device recognition service with an English pack; iOS needs OS-level
  on-device support. `capabilities` is the source of truth on each device.
- Continuous ASR is battery-heavy by design: this POC listens only while
  the app is foreground and explicitly enabled. A production background
  hotword engine is future work — do not call this bridge always-on voice.
- Synthetic test speech only; never real patient audio. No S24
  performance claim follows from emulator or simulator runs.

## Android regression and speech checks

With the latest debug APK installed on an API33+ emulator, run
`checks/android_voice_probe/run.sh`. It verifies full-width channel session
arguments, installed-English locale selection, and offline/wake-hint intent
fields against the actual native bridge. It neither captures audio nor reads
profile data. Instrumentation stops the app process; relaunch afterward.

`checks/android_voice_smoke.dart` is a separate manual speech test. Say
“Hey aa-yuh-mit-ra, show my reports” with microphone permission and an
installed English speech model. It logs only whether that synthetic command
matched, never recognized text. It reports a timeout rather than claiming a
pass when no command arrived. Native argument tests and text-matcher tests
do not prove recognition of a real speaker's accent.

The API36 development emulator currently has no installed English model;
its system-model download request did not finish during verification. This
blocks actual speech recognition there. The app fails closed with the missing
English-model message and never uses a cloud recognizer. A device with an
installed offline English model is needed for the remaining spoken check.
