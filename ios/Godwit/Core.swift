import Foundation
import Godwit
import Security
import os

let coreLog = Logger(subsystem: "com.jordanlyall.godwit", category: "core")

/// Backs core.Options.Keyring with the iOS keychain (one generic-password item
/// per service/account). Readable after first unlock so background refresh can sign in.
final class KeychainHost: NSObject, MobileHostProtocol {
    private func query(_ service: String?, _ account: String?) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? "",
         kSecAttrAccount as String: account ?? ""]
    }

    private func failure(_ status: OSStatus) -> NSError {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "keychain error \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: msg])
    }

    func secretGet(_ service: String?, account: String?, error: NSErrorPointer) -> String {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = out as? Data else {
            error?.pointee = failure(status)
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    func secretSet(_ service: String?, account: String?, value: String?) throws {
        let data = Data((value ?? "").utf8)
        let q = query(service, account)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure(update) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    func secretDelete(_ service: String?, account: String?) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    // Core lines can carry addresses and server names: public only in debug builds.
    func log(_ line: String?) {
        #if DEBUG
        coreLog.info("\(line ?? "", privacy: .public)")
        #else
        coreLog.info("\(line ?? "", privacy: .private)")
        #endif
    }
}

final class EventSink: NSObject, MobileEventSinkProtocol {
    let handler: (CoreEvent) -> Void
    init(_ handler: @escaping (CoreEvent) -> Void) { self.handler = handler }
    func onEvent(_ eventJSON: String?) {
        guard let json = eventJSON, let e = try? Core.decoder.decode(CoreEvent.self, from: Data(json.utf8)) else { return }
        handler(e)
    }
}

struct CoreError: LocalizedError {
    let method: String
    let message: String
    var errorDescription: String? { message }
}

/// The in-process Local API. Every call runs off the main thread.
enum Core {
    private static let host = KeychainHost()
    private static var sink: EventSink?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in GoKey(keys.last!.stringValue) }
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = goDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()
    static func goDate(_ s: String) -> Date? { fractional.date(from: s) ?? whole.date(from: s) }

    /// The data directory must be short: the Local API socket lives in it and
    /// sun_path allows 103 bytes. On a device that means Documents itself.
    static var dataDir: String {
        #if targetEnvironment(simulator)
        let dir = "/tmp/godwit-ios"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        #endif
    }

    static func start(onEvent: @escaping (CoreEvent) -> Void) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let language = Locale.preferredLanguages.first ?? "en"
        try await Task.detached(priority: .userInitiated) {
            var err: NSError?
            guard MobileStart(dataDir, language, version, host, &err) else {
                throw CoreError(method: "Start", message: err?.localizedDescription ?? "core did not start")
            }
            let s = EventSink(onEvent)
            guard MobileSubscribe(s, &err) else {
                throw CoreError(method: "Subscribe", message: err?.localizedDescription ?? "subscribe failed")
            }
            sink = s
        }.value
    }

    /// Calls a Local API method with positional params (JSON-serializable values).
    @discardableResult
    static func raw(_ method: String, _ params: [Any] = []) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: params, options: [.fragmentsAllowed])
        let paramsJSON = String(decoding: body, as: UTF8.self)
        return try await Task.detached(priority: .userInitiated) {
            var err: NSError?
            let res = MobileCall(method, paramsJSON, &err)
            if let err {
                coreLog.error("\(method, privacy: .public): \(err.localizedDescription, privacy: .private)")
                throw CoreError(method: method, message: err.localizedDescription)
            }
            return Data(res.utf8)
        }.value
    }

    static func call<T: Decodable>(_ method: String, _ params: [Any] = [], as: T.Type = T.self) async throws -> T {
        try decoder.decode(T.self, from: try await raw(method, params))
    }
}

/// Maps Go's exported field names to Swift's: ID → id, ThreadID → threadID,
/// IMAPHost → imapHost, LastDate → lastDate.
struct GoKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ go: String) {
        let chars = Array(go)
        var i = 0
        while i < chars.count, chars[i].isUppercase { i += 1 }
        if i == 0 { stringValue = go; return }
        // An acronym run keeps its last capital when a lowercase letter follows (IMAPHost → imapHost).
        let cut = (i < chars.count && i > 1) ? i - 1 : i
        stringValue = String(chars[..<cut]).lowercased() + String(chars[cut...])
    }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
