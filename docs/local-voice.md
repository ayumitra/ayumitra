# Local voice input

Tap the microphone to speak a command, or enable **Hey Ayumitra** while the companion screen is open. Final recognized speech follows the normal chat path and is saved as a user turn in that profile’s encrypted conversation.

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
  Every session event echoes the `start` call's id, captured per session —
  native never re-reads a mutable id when a queued callback runs, and keeps
  its independent generation guards. Dart strictly rejects events whose id
  does not match the live session (profile, conversation, route, or app
  change). Transcripts never appear in
  logs — lifecycle and error logs carry codes only.

## Android (`LocalVoiceBridge.kt`)

- Requires API 31+: `isOnDeviceRecognitionAvailable` gate plus
  `createOnDeviceSpeechRecognizer` only. `createSpeechRecognizer` is never
  used. Below API 31, `capabilities` reports unavailable with the reason.
- en-US (`EXTRA_LANGUAGE`) with `EXTRA_PREFER_OFFLINE`; on API 33+,
  `checkRecognitionSupport` must additionally confirm installed on-device
  English (`installedOnDeviceLanguages`) before listening, otherwise the
  session fails closed with `LANGUAGE_UNAVAILABLE`. There is no fallback
  language and no server recognizer.
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
