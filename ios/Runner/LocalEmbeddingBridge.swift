import Flutter
import Foundation
import LiteRTLM

/// EmbeddingGemma 2 via the official LiteRT-LM 0.18.0 Swift API.
/// Sources: upstream swift/EmbeddingEngine.swift and EmbeddingEngineConfig.swift.
/// No networking, input logging, or remote fallback.
@MainActor
final class LocalEmbeddingBridge {
  private static var instance: LocalEmbeddingBridge?
  private let channel: FlutterMethodChannel
  private let worker = EmbeddingWorker()
  private var pending: Task<Void, Never>?

  static func register(messenger: FlutterBinaryMessenger) {
    instance = LocalEmbeddingBridge(messenger: messenger)
  }

  private init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "app.ayumitra/embeddings", binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      // Flutter channels normally call on the main thread. Dispatch explicitly
      // so every enqueue and result also respects the main-actor contract.
      DispatchQueue.main.async {
        guard let self else {
          result(FlutterError(code: "NO_ENGINE", message: "Bridge unavailable.", details: nil))
          return
        }
        self.enqueue(call: call, result: result)
      }
    }
  }

  private func enqueue(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let operation: EmbeddingOperation
    switch call.method {
    case "load":
      guard let path = arguments?["path"] as? String else {
        result(FlutterError(code: "BAD_PATH", message: "Choose a local model file.", details: nil))
        return
      }
      operation = .load(path)
    case "embed":
      guard let raw = arguments?["text"] as? String else {
        result(FlutterError(code: "BAD_ARG", message: "Text is required.", details: nil))
        return
      }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.utf16.count <= 8000 else {
        result(FlutterError(code: "BAD_ARG", message: "Text must contain 1–8000 characters.", details: nil))
        return
      }
      operation = .embed(text)
    case "close":
      operation = .close
    default:
      result(FlutterMethodNotImplemented)
      return
    }

    // Actors can re-enter at await points. The task chain also serializes the
    // complete operations, so load/close cannot interrupt an embedding call.
    let previous = pending
    let worker = worker
    pending = Task {
      await previous?.value
      let reply = await worker.execute(operation)
      switch reply {
      case .success:
        result(true)
      case .vector(let values):
        result(values)
      case .failure(let code, let message):
        result(FlutterError(code: code, message: message, details: nil))
      }
    }
  }
}

private enum EmbeddingOperation: Sendable {
  case load(String)
  case embed(String)
  case close
}

private enum EmbeddingReply: Sendable {
  case success
  case vector([Double])
  case failure(String, String)
}

private actor EmbeddingWorker {
  private var engine: EmbeddingEngine?

  func execute(_ operation: EmbeddingOperation) async -> EmbeddingReply {
    switch operation {
    case .load(let path):
      guard path.hasPrefix("/"), path.lowercased().hasSuffix(".litertlm") else {
        return .failure("BAD_PATH", "Choose an existing local .litertlm file.")
      }
      let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
      var isDirectory: ObjCBool = false
      guard file.path.hasPrefix(NSHomeDirectory() + "/"),
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            FileManager.default.isReadableFile(atPath: file.path) else {
        return .failure("BAD_PATH", "Choose a readable model imported into this app.")
      }
      await engine?.close()
      engine = nil
      let next = EmbeddingEngine(config: EmbeddingEngineConfig(
        modelPath: file.path, backend: .cpu()
      ))
      do {
        try await next.initialize()
        engine = next
        return .success
      } catch {
        await next.close()
        return .failure("LOAD_FAILED", "Failed to load the local embedding model.")
      }

    case .embed(let text):
      guard let engine else {
        return .failure("NO_ENGINE", "Load a local embedding model first.")
      }
      do {
        let response = try await engine.computeEmbedding(contents: [.text(text)])
        let values = response.embedding.map { Double($0) }
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite }) else {
          return .failure("EMBED_FAILED", "The local model returned an invalid vector.")
        }
        return .vector(values)
      } catch {
        return .failure("EMBED_FAILED", "Local embedding failed.")
      }

    case .close:
      await engine?.close()
      engine = nil
      return .success
    }
  }
}
