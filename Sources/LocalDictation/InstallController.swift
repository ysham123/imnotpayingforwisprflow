import AppKit
import Foundation
import CryptoKit
import Darwin

/// Runs before permission requests, shortcut registration, or local engines.
/// Finder performs the standard drag-to-Applications installation.
@MainActor
final class InstallController {
    private let bundle: Bundle
    init(bundle: Bundle = .main) { self.bundle = bundle }

    func ensureInstalled() async -> Bool {
        guard bundle.bundleURL.pathExtension == "app", let identifier = bundle.bundleIdentifier else { return true }
        if identifier.hasSuffix(".development") { return true }
        let current = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let locations = [URL(fileURLWithPath: "/Applications"), userApplications]
            .map { $0.appendingPathComponent("Local Dictation.app") }
        if locations.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == current }) { return true }
        let alert = NSAlert()
        alert.messageText = "Move Local Dictation to Applications"
        alert.informativeText = "Drag Local Dictation onto the Applications folder in the disk image. Then open it from Applications to set up permissions. If you’re updating, quit the old app before replacing it."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([bundle.bundleURL])
        }
        return false
    }
}

/// The same-volume swap publishes a fully verified app and restores the old app
/// on any final verification failure. Tests inject only copy/verify/running probes.
enum AppInstallTransaction {
    static func install(source: URL, target: URL, expectedIdentifier: String,
                        copy: ((URL, URL) throws -> Void)? = nil,
                        verify: ((URL) throws -> Void)? = nil,
                        running: (() throws -> Bool)? = nil,
                        rename: ((URL, URL, UInt32) throws -> Void)? = nil) throws {
        let manager = FileManager.default
        guard source.standardizedFileURL != target.standardizedFileURL,
              target.pathExtension == "app" else { throw RuntimeSetupError.message("Choose a different real installation path.") }
        let parent = target.deletingLastPathComponent()
        try rejectLink(target); try rejectLink(parent)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let lock = try InstallFileLock(at: parent.appendingPathComponent(".localdictation-install.lock"))
        defer { lock.release() }
        let isRunning = running ?? { try Self.running(at: target) }
        let requirement = verify == nil ? try Self.requirement(source) : nil
        let verification = verify ?? { try Self.verify($0, expectedIdentifier: expectedIdentifier, requirement: requirement) }
        guard try !isRunning() else { throw RuntimeSetupError.message("Quit the installed app before updating it.") }
        try verification(source)
        let replacing = manager.fileExists(atPath: target.path)
        let atomicRename = rename ?? Self.atomicRename
        let stageRoot = parent.appendingPathComponent(".localdictation-stage-" + UUID().uuidString)
        try manager.createDirectory(at: stageRoot, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let stage = stageRoot.appendingPathComponent(target.lastPathComponent)
        var installed = false, keepRecovery = false
        defer { if !keepRecovery { try? manager.removeItem(at: stageRoot) } }
        do {
            if let copy { try copy(source, stage) }
            else { try command("/usr/bin/ditto", ["--rsrc", "--extattr", source.path, stage.path]) }
            try cleanFinderMetadata(stage)
            try verification(stage)
            try Task.checkCancellation()
            guard try !isRunning() else { throw RuntimeSetupError.message("The installed app opened during installation. Quit it and retry.") }
            try rejectLink(target)
            // An update exchanges both complete bundles in one syscall. The
            // old app remains at `stage` until the new canonical copy passes.
            // Fresh publication rejects a target created during preparation.
            try atomicRename(stage, target, UInt32(replacing ? RENAME_SWAP : RENAME_EXCL))
            installed = true
            try cleanFinderMetadata(target)
            try verification(target)
        } catch let failure {
            if installed {
                do {
                    if replacing { try atomicRename(stage, target, UInt32(RENAME_SWAP)) }
                    else { try atomicRename(target, stage, UInt32(RENAME_EXCL)) }
                } catch {
                    keepRecovery = true
                    if replacing {
                        throw RuntimeSetupError.message("Installation rollback needs attention. Your previous app is preserved at \(stage.path).")
                    }
                    throw RuntimeSetupError.message("Installation rollback needs attention. Check \(target.path) in Finder; temporary files are preserved at \(stageRoot.path).")
                }
            }
            throw failure
        }
    }

    private static func atomicRename(_ source: URL, _ target: URL, _ flags: UInt32) throws {
        guard renamex_np(source.path, target.path, flags) == 0 else {
            let reason = String(cString: strerror(errno))
            throw RuntimeSetupError.message("The app could not be installed atomically (\(reason)). Use Finder or retry; the existing app has not been removed.")
        }
    }

    private static func rejectLink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            throw RuntimeSetupError.message("The installation path is a symbolic link. Use its real folder in Finder.")
        }
    }

    private static func running(at app: URL) throws -> Bool {
        let expected = app.appendingPathComponent("Contents/MacOS/LocalDictation").path
        let output = try command("/bin/ps", ["-axo", "comm="], capture: true)
        return output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == expected }
    }

    private static func requirement(_ app: URL) throws -> String {
        let output = try command("/usr/bin/codesign", ["--display", "-r-", app.path], capture: true)
        for line in output.split(separator: "\n") {
            if let range = line.range(of: "designated => ") {
                return String(line[range.upperBound...])
            }
        }
        throw RuntimeSetupError.message("The downloaded app has no verifiable signing identity.")
    }

    private static func verify(_ app: URL, expectedIdentifier: String, requirement: String?) throws {
        guard Bundle(url: app)?.bundleIdentifier == expectedIdentifier,
              Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "LocalDictation" else {
            throw RuntimeSetupError.message("The downloaded app has an unexpected identity or executable.")
        }
        let executable = app.appendingPathComponent("Contents/MacOS/LocalDictation")
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RuntimeSetupError.message("The downloaded executable is missing or incomplete.")
        }
        var arguments = ["--verify", "--deep", "--strict"]
        if let requirement { arguments += ["--test-requirement", "=" + requirement] }
        try command("/usr/bin/codesign", arguments + [app.path])
    }

    private static func cleanFinderMetadata(_ app: URL) throws {
        for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"] {
            // Preserve quarantine; these two non-code attributes alone can make
            // signatures fail after File Provider/Finder copies.
            _ = try? command("/usr/bin/xattr", ["-dr", attribute, app.path])
        }
    }

    @discardableResult
    private static func command(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> String {
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        let output = Pipe(); child.standardOutput = capture ? output : FileHandle.nullDevice
        child.standardError = capture ? output : FileHandle.nullDevice
        try child.run()
        let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else {
            throw RuntimeSetupError.message("App copy or signature verification failed (\(URL(fileURLWithPath: executable).lastPathComponent)).")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class InstallFileLock {
    private var descriptor: Int32
    init(at url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeSetupError.message("The installation folder is not writable.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw RuntimeSetupError.message("Another installer is running. Wait for it to finish.")
        }
    }
    func release() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
