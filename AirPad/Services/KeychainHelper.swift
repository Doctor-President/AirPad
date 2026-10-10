import Foundation
import Security

struct KeychainHelper {

    /// Step 1 (T 2026-10-10) — readable once the device has been unlocked after a restart, so a launch while the phone
    /// is locked (a background refresh, the share extension) still finds the pairing. ThisDeviceOnly: the secret never
    /// travels in a backup to another device.
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private static let service = "com.doctorpresident.airpad"

    @discardableResult
    static func save(key: String, value: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecAttrService:      service,
            kSecValueData:        data,
            kSecAttrAccessible:   accessibility,
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
            kSecAttrService:  service,
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
            kSecAttrService: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Step 1 (T 2026-10-10) — items saved by older builds are `WhenUnlocked`; move every AirPad item to the current
    /// class IN PLACE (same value, no re-pair). Idempotent, so it runs every launch; while the device is locked the
    /// update fails and the next launch retries.
    static func migrateAccessibility() {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  item[kSecAttrAccessible as String] as? String != accessibility as String else { continue }
            let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
            let status = SecItemUpdate(match as CFDictionary, [kSecAttrAccessible: accessibility] as CFDictionary)
            NSLog("[Keychain] migrate %@ to AfterFirstUnlockThisDeviceOnly (%d)", account, status)
        }
    }

    #if DEBUG
    /// Step 1 self-test — `-KeychainMigrationSelfTest YES`: an item saved the OLD way (`WhenUnlocked`, as every build
    /// before this one saved the pairing) must come out of `migrateAccessibility` as `AfterFirstUnlockThisDeviceOnly`
    /// with its value intact (T must not have to re-pair), and a fresh `save` must use the new class.
    static func runMigrationSelfTest() {
        let legacy = "selftestLegacyItem", fresh = "selftestFreshItem"
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        func accessible(_ key: String) -> String {
            var q = base; q[kSecAttrAccount] = key; q[kSecReturnAttributes] = true; q[kSecMatchLimit] = kSecMatchLimitOne
            var r: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let a = r as? [String: Any] else { return "missing" }
            return a[kSecAttrAccessible as String] as? String ?? "?"
        }
        var add = base; add[kSecAttrAccount] = legacy; add[kSecValueData] = Data("pairing-v1".utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        delete(key: legacy); delete(key: fresh)
        let seeded = SecItemAdd(add as CFDictionary, nil)
        let before = accessible(legacy)
        migrateAccessibility()
        let after = accessible(legacy), value = load(key: legacy) ?? "nil"
        save(key: fresh, value: "x")
        let saved = accessible(fresh)
        let want = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        let ok = seeded == errSecSuccess && before == (kSecAttrAccessibleWhenUnlocked as String) && after == want
            && value == "pairing-v1" && saved == want
        NSLog("[KeychainMigrationSelfTest] %@ (seeded=%d before=%@ after=%@ value=%@ fresh=%@ want=%@)",
              ok ? "PASS" : "FAIL", seeded, before, after, value, saved, want)
        delete(key: legacy); delete(key: fresh)
    }

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
