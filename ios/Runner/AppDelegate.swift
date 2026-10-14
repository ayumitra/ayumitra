import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyChannel: FlutterMethodChannel?
  private var appLockChannel: FlutterMethodChannel?
  private var localPicker: AyumitraFilePicker?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Foreground-only voice: release the mic when leaving the app. There is
  // no background service and no always-on hotword engine.
  override func applicationWillResignActive(_ application: UIApplication) {
    AyumitraPrivacyShield.shared.show()
    LocalVoiceBridge.shared.handleAppBackground()
    super.applicationWillResignActive(application)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    LocalVoiceBridge.shared.handleAppTerminate()
    super.applicationWillTerminate(application)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AyumitraPrivacy") else { return }
    let channel = FlutterMethodChannel(name: "app.ayumitra/privacy", binaryMessenger: registrar.messenger())
    privacyChannel = channel
    let appLock = FlutterMethodChannel(name: "app.ayumitra/app_lock", binaryMessenger: registrar.messenger())
    appLockChannel = appLock
    appLock.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "BAD_ARGUMENT", message: "A privacy setting is required.", details: nil)); return
      }
      switch call.method {
      case "setPrivacyEnabled":
        guard let enabled = args["enabled"] as? Bool else {
          result(FlutterError(code: "BAD_ARGUMENT", message: "A privacy setting is required.", details: nil)); return
        }
        AyumitraPrivacyShield.shared.setEnabled(enabled)
        result(true)
      case "setPrivacyVisible":
        guard let visible = args["visible"] as? Bool else {
          result(FlutterError(code: "BAD_ARGUMENT", message: "A privacy visibility setting is required.", details: nil)); return
        }
        AyumitraPrivacyShield.shared.setVisible(visible)
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
    // Register scene-inactive observation before displaying health content.
    _ = AyumitraPrivacyShield.shared
    LocalEmbeddingBridge.register(messenger: registrar.messenger())
    LocalVoiceBridge.register(messenger: registrar.messenger())
    let picker = AyumitraFilePicker()
    localPicker = picker
    let pickerChannel = FlutterMethodChannel(name: "app.ayumitra/picker", binaryMessenger: registrar.messenger())
    pickerChannel.setMethodCallHandler { [weak self] call, result in
      let presenter = self?.window?.rootViewController ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?.rootViewController
      guard call.method == "pick", let presenter = presenter else {
        result(FlutterMethodNotImplemented); return
      }
      picker.pick(from: presenter, result: result)
    }
    channel.setMethodCallHandler { call, result in
      if call.method == "getTemporaryRoot" { result(NSTemporaryDirectory()); return }
      guard call.method == "protectDirectory",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            path.hasPrefix(NSHomeDirectory() + "/") else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
        result(true)
      } catch {
        result(FlutterError(code: "PROTECTION_FAILED", message: "Local file protection could not be applied.", details: nil))
      }
    }
  }
}

/// Obscures app-switcher snapshots while optional app lock is enabled. This
/// does not block screenshots while iOS is active. No secure-text-field hacks.
/// Covers remain after activation until Dart has rendered its lock/unlocked
/// gate and calls setPrivacyVisible(false). Inactive alone never requests auth.
final class AyumitraPrivacyShield: NSObject {
  static let shared = AyumitraPrivacyShield()
  private var enabled = true
  private var covers: [ObjectIdentifier: UIView] = [:]

  private override init() {
    super.init()
    // Scene-based apps need this notification: applicationWillResignActive is
    // only a fallback for older lifecycle forwarding. The observer adds no
    // SceneDelegate override, preserving Flutter's existing scene callbacks.
    NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
      name: UIScene.willDeactivateNotification, object: nil)
  }

  @objc private func sceneWillDeactivate(_ notification: Notification) {
    show(scene: notification.object as? UIScene)
  }

  func setEnabled(_ next: Bool) {
    enabled = next
    if !next {
      removeCovers()
    } else if UIApplication.shared.applicationState != .active {
      show()
    }
  }

  func setVisible(_ visible: Bool) {
    guard enabled else { removeCovers(); return }
    if visible || UIApplication.shared.applicationState != .active {
      show()
    } else {
      removeCovers()
    }
  }

  func show(scene: UIScene? = nil) {
    guard enabled else { return }
    let scenes = scene.map { [$0] } ?? Array(UIApplication.shared.connectedScenes)
    for windowScene in scenes.compactMap({ $0 as? UIWindowScene }) {
      for window in windowScene.windows where !window.isHidden && window.windowLevel == .normal {
        let key = ObjectIdentifier(window)
        if let cover = covers[key] {
          window.bringSubviewToFront(cover)
          continue
        }
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .systemBackground
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = true
        cover.accessibilityViewIsModal = true
        cover.accessibilityIdentifier = "ayumitra-privacy-shield"
        let label = UILabel()
        label.text = "Ayumitra"
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(label)
        NSLayoutConstraint.activate([
          label.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
          label.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
        window.addSubview(cover)
        covers[key] = cover
      }
    }
  }

  private func removeCovers() {
    for cover in covers.values { cover.removeFromSuperview() }
    covers.removeAll()
  }
}

/// Owns only Caches/ayumitra-picker. No file is staged in a shared temp folder.
private final class AyumitraFilePicker: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  func pick(from presenter: UIViewController, result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "BUSY", message: "A file picker is already open.", details: nil)); return
    }
    pending = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    presenter.present(picker, animated: true)
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pending?(nil); pending = nil
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let source = urls.first, let result = pending else { return }
    pending = nil
    DispatchQueue.global(qos: .userInitiated).async {
      let access = source.startAccessingSecurityScopedResource()
      defer { if access { source.stopAccessingSecurityScopedResource() } }
      var destinationDirectory: URL?
      do {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("ayumitra-picker", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        destinationDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
          attributes: [.protectionKey: FileProtectionType.complete])
        let target = directory.appendingPathComponent(source.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
          do { try FileManager.default.copyItem(at: url, to: target) } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
        DispatchQueue.main.async { result(["path": target.path]) }
      } catch {
        if let directory = destinationDirectory { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.main.async { result(FlutterError(code: "IMPORT_FAILED", message: "The local file could not be opened.", details: nil)) }
      }
    }
  }
}
