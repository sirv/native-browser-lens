import Foundation
#if os(Linux)

public enum KeychainStore {
    private static func run(_ arguments: [String], input: String? = nil) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/secret-tool")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output; process.standardError = errors; process.standardInput = stdin
        do { try process.run() }
        catch { throw LensError.storage("Install secret-tool and start a Secret Service keyring to store credentials") }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 1 && diagnostic.isEmpty && arguments.first != "store" { return nil }
        guard process.terminationStatus == 0 else { throw LensError.storage("Could not access the Secret Service keyring. Unlock your desktop keyring and retry.") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    public static func get(key: String) throws -> String? {
        try run(["lookup", "service", "studio.sirv.native-browser-lens", "account", key])
    }
    public static func set(key: String, value: String) throws {
        let attributes = ["service", "studio.sirv.native-browser-lens", "account", key]
        if value.isEmpty { _ = try run(["clear"] + attributes) }
        else { _ = try run(["store", "--label=Native Browser Lens: " + key] + attributes, input: value) }
    }
}
#else
import Security

public enum KeychainStore {
    private static let service = "studio.sirv.native-browser-lens"
    public static func get(key: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LensError.storage("Could not read the credential from Keychain") }
        return String(data: data, encoding: .utf8)
    }
    public static func set(key: String, value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        if value.isEmpty { let result = SecItemDelete(query as CFDictionary); guard result == errSecSuccess || result == errSecItemNotFound else { throw LensError.storage("Could not remove the Keychain credential") }; return }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw LensError.storage("Could not update Keychain credential") }
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LensError.storage("Could not save Keychain credential") }
    }
}
#endif
