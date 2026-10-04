import Foundation
import Security
import CryptoKit

/// Bounded local troubleshooting records. Never accepts text, audio, key events,
/// application names, or vocabulary as inputs.
@MainActor
final class PermissionDiagnostics {
    enum Event: String { case readinessChanged, listenerRetry }
    struct Readiness: Codable, Equatable {
        let microphone: Int
        let accessibility: Bool
        let inputMonitoring: Bool
        let listenerActive: Bool
        let listenerError: String?
    }
    private struct Record: Codable {
        let date: Date
        let launch: UUID
        let pid: Int32
        let event: String
        let bundlePath: String
        let bundleIdentifier: String
        let version: String
        let build: String
        let executableSHA256: String?
        let codeHash: String?
        let designatedRequirement: String?
        let readiness: Readiness
    }
    private let launch = UUID()
    private let bundle: Bundle
    private let destination: URL
    private let executableSHA256: String?
    private let codeHash: String?
    private let designatedRequirement: String?
    private var last: Readiness?

    init(bundle: Bundle = .main, destination: URL? = nil) {
        self.bundle = bundle
        self.destination = destination ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Local Dictation/Diagnostics/readiness.json")
        if let executable = bundle.executableURL, let data = try? Data(contentsOf: executable, options: .mappedIfSafe) {
            executableSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else { executableSHA256 = nil }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let info = information as? [String: Any] {
            codeHash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
            var requirementText: CFString?
            if let requirement = info[kSecCodeInfoDesignatedRequirement as String] {
                let typed = requirement as! SecRequirement
                if SecRequirementCopyString(typed, [], &requirementText) == errSecSuccess {
                    designatedRequirement = requirementText as String?
                } else { designatedRequirement = nil }
            } else { designatedRequirement = nil }
        } else { codeHash = nil; designatedRequirement = nil }
    }

    func record(_ readiness: Readiness, event: Event = .readinessChanged, force: Bool = false) {
        guard force || readiness != last else { return }
        last = readiness
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var rows = (try? Data(contentsOf: destination)).flatMap { try? decoder.decode([Record].self, from: $0) } ?? []
        rows.append(Record(date: Date(), launch: launch, pid: ProcessInfo.processInfo.processIdentifier,
                           event: event.rawValue, bundlePath: bundle.bundleURL.path,
                           bundleIdentifier: bundle.bundleIdentifier ?? "development",
                           version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                           build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                           executableSHA256: executableSHA256, codeHash: codeHash,
                           designatedRequirement: designatedRequirement, readiness: readiness))
        rows = Array(rows.suffix(64))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try encoder.encode(rows).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { /* Diagnostics never prevent dictation or request broader access. */ }
    }

    func export() throws -> Data { try Data(contentsOf: destination) }
}
