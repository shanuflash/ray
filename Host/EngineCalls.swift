import AppKit

enum EngineCalls {
  private typealias Reply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
  private typealias Call = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, Reply?, UnsafeMutableRawPointer?
  ) -> Void

  private final class Pending {
    let completion: ([String: Any]?) -> Void
    init(_ completion: @escaping ([String: Any]?) -> Void) { self.completion = completion }
  }

  private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

  static func call(
    _ name: String, profile: RayCoreProfile, args: [String: Any] = [:],
    completion: @escaping ([String: Any]?) -> Void
  ) {
    guard let data = try? JSONSerialization.data(withJSONObject: args) else {
      completion(nil)
      return
    }
    call(name, profile: profile, json: data, completion: completion)
  }

  /// `call` with the arguments already serialised (by `JSONSerialization`, off the main thread for big batches such
  /// as imported history). Main thread only, like every engine call.
  static func call(
    _ name: String, profile: RayCoreProfile, json: Data, completion: @escaping ([String: Any]?) -> Void
  ) {
    var terminated = json
    terminated.append(0)
    terminated.withUnsafeBytes { bytes in
      invoke(name, profile: profile, args: bytes.baseAddress!.assumingMemoryBound(to: CChar.self), completion: completion)
    }
  }

  /// For arguments that carry secrets (cookie values, passwords, card numbers), written straight into `SecretBytes`
  /// (`CookieWire`, `AutofillWire`): the bytes go to the engine as they are, NUL-terminated, never through a Swift
  /// String, and are wiped as soon as the call returns. The engine parses them inside the call (`SensitiveArgs`, which
  /// cleanses its own copy), so nothing reads them afterwards. Main thread only.
  static func callWithSecret(
    _ name: String, profile: RayCoreProfile, json: SecretBytes, completion: @escaping ([String: Any]?) -> Void
  ) {
    let terminated = json.count > 0 && json.withUnsafeBytes({ $0[$0.count - 1] }) == 0
    let bytes = terminated ? json : {
      let copy = SecretBytes(count: json.count + 1)
      json.withUnsafeBytes { src in
        copy.withUnsafeMutableBytes { dst in
          if let base = src.baseAddress, src.count > 0 { dst.baseAddress!.copyMemory(from: base, byteCount: src.count) }
        }
      }
      return copy
    }()
    bytes.withUnsafeBytes { raw in
      invoke(name, profile: profile, args: raw.baseAddress!.assumingMemoryBound(to: CChar.self), completion: completion)
    }
    bytes.wipe()
    json.wipe()
  }

  private static func invoke(
    _ name: String, profile: RayCoreProfile, args: UnsafePointer<CChar>,
    completion: @escaping ([String: Any]?) -> Void
  ) {
    guard let symbol = dlsym(defaultHandle, name) else {
      completion(nil)
      return
    }
    let function = unsafeBitCast(symbol, to: Call.self)
    let context = Unmanaged.passRetained(Pending(completion)).toOpaque()
    let reply: Reply = { context, json in
      guard let context else { return }
      let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
      let result = json
        .flatMap { try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8)) }
        as? [String: Any]
      if Thread.isMainThread {
        pending.completion(result)
      } else {
        DispatchQueue.main.async { pending.completion(result) }
      }
    }
    function(profile.path, args, reply, context)
  }
}

/// The engine's events (`downloads.changed`, …): one sink for the whole app, handed out by topic on the main thread.
enum EngineEvents {
  private typealias Sink = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
  private typealias SetSink = @convention(c) (Sink?, UnsafeMutableRawPointer?) -> Void

  private static var handlers: [String: [([String: Any]) -> Void]] = [:]
  private static var started = false

  static func on(_ topic: String, _ handler: @escaping ([String: Any]) -> Void) {
    handlers[topic, default: []].append(handler)
    start()
  }

  private static func start() {
    guard !started, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ac_engine_set_event_sink") else { return }
    started = true
    let sink: Sink = { _, topic, json in
      guard let topic else { return }
      let name = String(cString: topic)
      let payload = json
        .flatMap { try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8)) } as? [String: Any] ?? [:]
      let deliver: () -> Void = { EngineEvents.handlers[name]?.forEach { $0(payload) } }
      if Thread.isMainThread { deliver() } else { DispatchQueue.main.async { deliver() } }
    }
    unsafeBitCast(symbol, to: SetSink.self)(sink, nil)
  }
}
