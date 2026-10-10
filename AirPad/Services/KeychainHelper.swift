import Foundation
import Security

struct KeychainHelper {

    @discardableResult
    static func save(key: String, value: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecAttrService:      "com.doctorpresident.airpad",
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { NSLog("[Keychain] save %@ failed (%d)", key, status) }
        return status
    }

    /// C2c — what a read found. `.failed` (a locked device's errSecInteractionNotAllowed, an XPC hiccup) is NOT
    /// `.notFound`: callers that gate on an item's presence must not read a failure as "absent".
    enum ReadResult { case found(String), notFound, failed(OSStatus) }

    static func read(key: String) -> ReadResult {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrAccount:  key,
            kSecAttrService:  "com.doctorpresident.airpad",
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        #if DEBUG
        if debugStubbedReadFailure(key) { return .failed(errSecInteractionNotAllowed) }
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
            return .found(s)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    static func load(key: String) -> String? {
        if case .found(let s) = read(key: key) { return s }
        return nil
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.doctorpresident.airpad",
        ]
        SecItemDelete(query as CFDictionary)
    }

    #if DEBUG
    /// C2c test hook — `-StubPairingReadFailsAfter <n>`: after n reads of the pairing item, every later read fails as a
    /// locked device's does (errSecInteractionNotAllowed), so a UI test can prove a failed read never unpairs.
    private static var debugPairingReads = 0
    static func debugStubbedReadFailure(_ key: String) -> Bool {
        let n = UserDefaults.standard.integer(forKey: "StubPairingReadFailsAfter")
        guard n > 0, key == "airpadHostPairing" else { return false }
        debugPairingReads += 1
        return debugPairingReads > n
    }
    #endif
}
