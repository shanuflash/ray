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
    _ name: String, profile: ArdiaCoreProfile, args: [String: Any] = [:],
    completion: @escaping ([String: Any]?) -> Void
  ) {
    guard let symbol = dlsym(defaultHandle, name),
          let data = try? JSONSerialization.data(withJSONObject: args),
          let json = String(data: data, encoding: .utf8) else {
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
    function(profile.path, json, reply, context)
  }
}
