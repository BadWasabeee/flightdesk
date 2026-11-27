// Secrets shared by the app and its widget, kept in the Keychain (never in defaults or files).
//
// - iPhone: the data protection keychain, in the keychain access group both targets are entitled
//   to (`FDKeychainGroup` in Info.plist, from `keychain-access-groups` in the entitlements).
// - Mac: the app and widget are signed without a provisioning profile, which rules out
//   `keychain-access-groups` (a restricted entitlement on macOS: the system refuses to launch the
//   app) and the data protection keychain. The token goes in the login keychain instead, with an
//   access list that trusts exactly the app and the widgets inside it, so the widget reads it
//   without a prompt and other apps can't.

import Foundation
import Security

/// Somewhere to keep one secret string.
protocol SecretStore: Sendable {
    /// The stored value, or nil when there is none (or it can't be read).
    func read() -> String?
    /// Stores `value`, or removes the stored value when nil or empty.
    func write(_ value: String?) throws
}

/// A Keychain failure, with the `OSStatus` for diagnostics.
struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus
    var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain couldn’t save the token (\(text))."
    }
}

/// One generic-password item in the Keychain, shared by the app and its widget.
struct KeychainSecretStore: SecretStore {
    let service: String
    let account: String
    /// The access group on iOS (ignored on macOS; see the file comment). Nil uses the default group.
    let accessGroup: String?

    /// The FlightDesk server token.
    static let serverToken = KeychainSecretStore(service: "flightdesk.server", account: "token",
                                                 accessGroup: configuredAccessGroup)

    /// `FDKeychainGroup` from Info.plist, when the build expanded it to a team-prefixed group.
    static var configuredAccessGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "FDKeychainGroup") as? String,
              !g.isEmpty, !g.contains("$("), !g.hasPrefix(".") else { return nil }
        return g
    }

    func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecMissingEntitlement, accessGroup != nil {
            // An unsigned or differently signed build: fall back to the default group.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemCopyMatching(query as CFDictionary, &out)
        }
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?) throws {
        var status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecMissingEntitlement, accessGroup != nil {
            var q = baseQuery()
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemDelete(q as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        guard let value, !value.isEmpty else { return }

        var add = baseQuery()
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "FlightDesk server token"
        #if os(macOS)
        if let access = LegacyKeychainAccess.make(label: "FlightDesk server token") {
            add[kSecAttrAccess as String] = access
        }
        #else
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement, accessGroup != nil {
            add.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS)
        q[kSecUseDataProtectionKeychain as String] = true
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        #endif
        return q
    }
}

/// An in-memory store, for tests and previews.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    /// Times `read()` was called.
    private(set) var reads = 0

    init(_ value: String? = nil) { self.value = value }

    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return value
    }

    func write(_ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        self.value = (value?.isEmpty ?? true) ? nil : value
    }
}

#if os(macOS)
/// The login-keychain access list for a shared item: this app (or widget) plus every app extension
/// inside the running app's bundle. Uses the file-based keychain's access APIs, which macOS still
/// requires for this (they are deprecated without a replacement for profile-less apps), so calls go
/// through a protocol to keep their deprecation warnings out of every build.
enum LegacyKeychainAccess {
    static func make(label: String) -> SecAccess? {
        let maker: LegacyAccessMaking = LegacyAccessMaker()
        return maker.access(label: label, extensions: extensionPaths())
    }

    /// The app extensions (widgets) bundled with the running app.
    static func extensionPaths(bundle: Bundle = .main) -> [String] {
        guard let dir = bundle.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "appex" }.map(\.path)
    }
}

private protocol LegacyAccessMaking {
    func access(label: String, extensions: [String]) -> SecAccess?
}

private struct LegacyAccessMaker: LegacyAccessMaking {
    @available(macOS, deprecated: 10.10)
    func access(label: String, extensions: [String]) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        for path in extensions {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
#endif
