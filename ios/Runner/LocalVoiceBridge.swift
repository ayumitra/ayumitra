import AVFoundation
import Flutter
import Speech

/// Strict on-device English speech bridge (Sub-owned file).
///
/// Channels: MethodChannel `app.ayumitra/voice` (`capabilities`,
/// `requestPermission`, `start {sessionId: Int}`, `stop`) and EventChannel
/// `app.ayumitra/voice_events` emitting `type` in
/// {partial, final, error, stopped} with the echoed `sessionId` plus
/// optional `text`/`code`/`reason`. Invalid `start` args fail the method
/// with BAD_SESSION_ID and start no session.
///
/// Hard rules (fail closed, never fall back):
/// - English `SFSpeechRecognizer` only, created per session; the request sets
///   `requiresOnDeviceRecognition = true` ALWAYS. Server recognition is never
///   used: no network audio, no model download.
/// - `start` requires `supportsOnDeviceRecognition` plus already-granted
///   mic/speech authorization. Authorization is requested only from
///   `requestPermission`, which Dart calls after an explicit user tap.
/// - `AVAudioEngine` uses ephemeral buffers; no audio files are written and
///   transcripts are never logged (lifecycle logs carry codes only).
/// - Listening runs only while the app is foreground and explicitly enabled;
///   AppDelegate stops the session on resign-active/terminate. There is no
///   background service and no always-on hotword engine.
/// - `final`/`stopped` are emitted exactly once per session; recognition
///   generation ids drop stale task callbacks.
final class LocalVoiceBridge: NSObject {
  static let shared = LocalVoiceBridge()

  private static let channelName = "app.ayumitra/voice"
  private static let eventsName = "app.ayumitra/voice_events"
  private static let localeID = "en-US"

  private var eventSink: FlutterEventSink?
  private var recognizer: SFSpeechRecognizer?
  private var audioEngine: AVAudioEngine?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var permissionResult: FlutterResult?
  private var generation = 0
  private var sessionActive = false
  private var activeSessionId: Int?

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = LocalVoiceBridge.shared
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      bridge.handle(call: call, result: result)
    }
    let events = FlutterEventChannel(name: eventsName, binaryMessenger: messenger)
    events.setStreamHandler(bridge)
  }

  // MARK: - App lifecycle (called from AppDelegate)

  func handleAppBackground() {
    stopSession(reason: "App moved to background — microphone released.")
  }

  func handleAppTerminate() {
    stopSession(reason: "App terminating — microphone released.")
  }

  // MARK: - Method channel

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilities())
    case "requestPermission":
      requestPermission(result: result)
    case "start":
      guard let args = call.arguments as? [String: Any],
        let sessionId = args["sessionId"] as? Int
      else {
        result(FlutterError(code: "BAD_SESSION_ID",
          message: "start requires an int sessionId.", details: nil))
        return
      }
      startSession(sessionId: sessionId)
      result(nil)
    case "stop":
      stopSession(reason: nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func capabilities() -> [String: Any] {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)) else {
      return unavailable(reason: "English speech recognition is not supported on this device.")
    }
    guard recognizer.supportsOnDeviceRecognition else {
      return unavailable(reason: "On-device speech recognition is not available on this device.")
    }
    return ["available": true, "onDevice": true, "platform": "ios"]
  }

  private func unavailable(reason: String) -> [String: Any] {
    return [
      "available": false, "onDevice": false, "platform": "ios", "reason": reason,
    ]
  }

  private func requestPermission(result: @escaping FlutterResult) {
    guard permissionResult == nil else {
      result(
        FlutterError(
          code: "PERMISSION_PENDING",
          message: "A microphone permission request is already in flight.", details: nil
        ))
      return
    }
    permissionResult = result
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard status == .authorized else {
        self?.finishPermission(granted: false)
        return
      }
      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] micGranted in
        self?.finishPermission(granted: micGranted)
      }
    }
  }

  private func finishPermission(granted: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let pending = self.permissionResult else { return }
      self.permissionResult = nil
      pending(granted)
    }
  }

  private func startSession(sessionId: Int) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)),
      recognizer.supportsOnDeviceRecognition
    else {
      emit(["type": "error", "sessionId": sessionId, "code": "NOT_AVAILABLE",
        "reason": "On-device English recognition is not available on this device."])
      return
    }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized,
      AVAudioSession.sharedInstance().recordPermission == .granted
    else {
      emit(["type": "error", "sessionId": sessionId, "code": "PERMISSION_REQUIRED",
        "reason": "Microphone and speech recognition permission are required. Call requestPermission after an explicit user action."])
      return
    }
    guard !sessionActive else {
      emit(["type": "error", "sessionId": sessionId, "code": "ALREADY_ACTIVE",
        "reason": "A voice session is already running."])
      return
    }
    generation += 1
    let owner = generation
    sessionActive = true
    activeSessionId = sessionId
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
      let engine = AVAudioEngine()
      let request = SFSpeechAudioBufferRecognitionRequest()
      // Never server recognition: on-device only, partials enabled.
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = true
      let inputNode = engine.inputNode
      let format = inputNode.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        failSession(owner: owner, code: "AUDIO_UNAVAILABLE",
          reason: "No local microphone input is available.")
        return
      }
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
      }
      self.recognizer = recognizer
      self.audioEngine = engine
      self.recognitionRequest = request
      engine.prepare()
      try engine.start()
      self.recognitionTask = recognizer.recognitionTask(with: request) {
        [weak self] result, error in
        // sessionId is a value parameter: captured by value here, never
        // re-read from mutable state when this queued callback runs.
        self?.handleRecognition(
          owner: owner, session: sessionId, text: result?.bestTranscription.formattedString,
          isFinal: result?.isFinal ?? false, error: error as NSError?
        )
      }
      if owner == generation && sessionActive {
        emit(["type": "ready", "sessionId": sessionId])
      }
    } catch {
      failSession(
        owner: owner, code: "START_FAILED",
        reason: "Listening could not start on-device."
      )
    }
  }

  private func handleRecognition(
    owner: Int, session: Int, text: String?, isFinal: Bool, error: NSError?
  ) {
    guard owner == generation, sessionActive else { return }
    if let error {
      generation += 1
      emit([
        "type": "error", "sessionId": session, "code": "RECOGNITION_\(error.code)",
        "reason": "On-device recognition failed without using the network.",
      ])
      endSession()
      return
    }
    let transcript = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else { return }
    if isFinal {
      generation += 1
      emit(["type": "final", "sessionId": session, "text": transcript])
      endSession()
    } else {
      emit(["type": "partial", "sessionId": session, "text": transcript])
    }
  }

  private func stopSession(reason: String?) {
    guard sessionActive, let sessionId = activeSessionId else { return }
    generation += 1
    if let reason {
      emit(["type": "stopped", "sessionId": sessionId, "reason": reason])
    } else {
      emit(["type": "stopped", "sessionId": sessionId])
    }
    endSession()
  }

  private func failSession(owner: Int, code: String, reason: String) {
    // Read the session id only while this generation is still current:
    // no newer session can exist here, so it cannot be mis-tagged.
    guard owner == generation, sessionActive, let sessionId = activeSessionId else { return }
    emit(["type": "error", "sessionId": sessionId, "code": code, "reason": reason])
    endSession()
  }

  private func endSession() {
    sessionActive = false
    activeSessionId = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    if let engine = audioEngine {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
    }
    audioEngine = nil
    recognizer = nil
    try? AVAudioSession.sharedInstance().setActive(
      false, options: .notifyOthersOnDeactivation)
  }

  private func emit(_ event: [String: Any]) {
    guard let sink = eventSink else { return }
    DispatchQueue.main.async { sink(event) }
  }
}

extension LocalVoiceBridge: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    // Dart is gone: release the mic without emitting.
    eventSink = nil
    generation += 1
    endSession()
    return nil
  }
}
