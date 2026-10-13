import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyChannel: FlutterMethodChannel?
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
