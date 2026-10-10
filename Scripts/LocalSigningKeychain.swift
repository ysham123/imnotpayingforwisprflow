// Local build tooling only. Passwords are read from a private file, never argv.
import Foundation
import Security

func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        throw NSError(domain: "LocalSigning", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "\(operation): \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"])
    }
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, ["create", "unlock", "lock"].contains(arguments[1]) else {
        throw NSError(domain: "LocalSigning", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Usage: LocalSigningKeychain create|unlock|lock KEYCHAIN PRIVATE_DIRECTORY"])
    }
    let directory = URL(fileURLWithPath: arguments[3], isDirectory: true)
    let password = try String(contentsOf: directory.appendingPathComponent("keychain-password"), encoding: .utf8)
    let bytes = Array(password.utf8)
    var keychain: SecKeychain?
    if arguments[1] == "create" {
        guard !FileManager.default.fileExists(atPath: arguments[2]) else {
            throw NSError(domain: "LocalSigning", code: 2, userInfo: [NSLocalizedDescriptionKey: "Keychain already exists"])
        }
        // SecKeychainCreate can add the new chain to the search list. Restore
        // the existing list immediately; builds use an explicit --keychain.
        var searchList: CFArray?
        try checked(SecKeychainCopySearchList(&searchList), "Read keychain search list")
        defer { if let searchList { _ = SecKeychainSetSearchList(searchList) } }
        try bytes.withUnsafeBytes { buffer in
            try checked(SecKeychainCreate(arguments[2], UInt32(buffer.count), buffer.baseAddress, false, nil, &keychain), "Create private signing keychain")
        }
        guard let keychain else { fatalError("Security returned no keychain") }
        defer { SecKeychainLock(keychain) }
        var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: true, useLockInterval: true, lockInterval: 300)
        try checked(SecKeychainSetSettings(keychain, &settings), "Set automatic keychain lock")
        var trusted: SecTrustedApplication?
        try checked(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted), "Limit signing-key access")
        var access: SecAccess?
        try checked(SecAccessCreate("Local Dictation local builds" as CFString, [trusted!] as CFArray, &access), "Create signing-key access control")
        let data = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        let options: [String: Any] = [kSecImportExportPassphrase as String: password,
                                    kSecImportExportKeychain as String: keychain,
                                    kSecImportExportAccess as String: access!]
        var items: CFArray?
        try checked(SecPKCS12Import(data as CFData, options as CFDictionary, &items), "Import local signing identity")
        print("Created locked signing keychain with codesign access only")
    } else {
        try checked(SecKeychainOpen(arguments[2], &keychain), "Open signing keychain")
        guard let keychain else { fatalError("Security returned no keychain") }
        if arguments[1] == "unlock" {
            try bytes.withUnsafeBytes { buffer in
                try checked(SecKeychainUnlock(keychain, UInt32(buffer.count), buffer.baseAddress, true), "Unlock signing keychain")
            }
        } else {
            try checked(SecKeychainLock(keychain), "Lock signing keychain")
        }
    }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
