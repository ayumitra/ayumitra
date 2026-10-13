# Local voice input

Tap the microphone to speak a command, or enable **Ayu** wake listening while the companion screen is open. Say “Ayu” (pronounced **aa-yuh**), as in “Ayu, show my reports,” or say “Ayu” first and then your command. The app remains named Ayumitra. Final recognized speech follows the normal chat path and is saved as a user turn in that profile’s encrypted conversation.

Voice input is explicit-tap, foreground-only, English-only, and strictly
on-device. There is no cloud fallback, no network audio, no model download,
no audio storage, and no background or always-on hotword service.

## Channel contract (both platforms)

- MethodChannel `app.ayumitra/voice`:
  - `capabilities` → `{available, onDevice, platform, reason?}`. `onDevice`
    is true whenever `available` is true: this bridge has no server mode.
    `reason` is present only when unavailable, and always truthful.
    Capabilities confirm only that an on-device speech backend exists;
    actual language support and microphone readiness require `start`.
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
  `{type: partial|final|error|stopped|ready, sessionId: int, text?, code?, reason?}`.
  `ready` fires once per session — actual Android `onReadyForSpeech`, iOS
  engine/task initialized — and Dart shows starting until it arrives.
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
  `checkRecognitionSupport` reads support metadata to prefer actually
  installed English (device-default English if installed, else en-US, else
  another installed English locale). Missing installed-model metadata is not
  proof English is unavailable: the same on-device recognizer — never a
  server recognizer — then attempts the selected English locale, and the
  recognizer's actual `LANGUAGE_UNAVAILABLE` / `LANGUAGE_NOT_SUPPORTED`
  errors are reported truthfully. Explicitly non-English support is refused.
  If the metadata query itself cannot run, the same local instance proceeds
  with standard en-US; the English display locale en-DE is not assumed to
  be a supported speech-model tag.
  Below API 33, en-US is the default. There is
  no model downloader, no non-English fallback, and no server fallback;
  privacy is unchanged (no cloud, no app download).
- On Android 13+, recognition receives local phrase-biasing hints for “Ayu” and narrowly spelled aa-yuh variants. The matcher requires the wake name at the beginning and ignores generic speech that merely mentions other words.
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
- Availability is device-dependent: Android needs an on-device recognition
  service, and an English pack may be reported, installed, or missing — the
  bridge attempts the selected English locale on the same local backend and
  reports the recognizer's actual language errors. iOS needs OS-level
  on-device support. `capabilities` confirms only that a backend exists;
  actual language support and readiness require `start`.
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
“Ayu (aa-yuh), show my reports” with microphone permission and an
installed English speech model. It logs only whether that synthetic command
matched, never recognized text. It reports a timeout rather than claiming a
pass when no command arrived. Native argument tests and text-matcher tests
do not prove recognition of a real speaker's accent.

The API36 development emulator currently has no installed English model;
its system-model download request did not finish during verification. This
blocks actual speech recognition there. The app fails closed with the missing
English-model message and never uses a cloud recognizer. A device with an
installed offline English model is needed for the remaining spoken check.
On 13 October 2026, a temporary developer instrumentation package downloaded
the S24's offline English asset and was removed. The phone reached actual
microphone READY. In the spoken test, the recognizer repeatedly transcribed
“Ayu” as “are you”; successful wake activation was not verified. Wake-word
development is now parked at the user's request while core report, memory,
and on-device model work continues. No alternative wake name has been chosen.
Tap-to-talk remains available through the same strictly local recognizer.
