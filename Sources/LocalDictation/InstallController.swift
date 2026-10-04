import AppKit
import Foundation
import CryptoKit
import Darwin

/// Runs before permission requests, shortcut registration, or local engines.
@MainActor
final class InstallController {
    private let bundle: Bundle
    private var installing = false

    init(bundle: Bundle = .main) { self.bundle = bundle }

    /// False means installation/cancellation was handled; caller should quit this
    /// source copy. A system launcher opens the verified installed copy after exit.
    func ensureInstalled() async -> Bool {
        guard !installing else { return false }
        guard bundle.bundleURL.pathExtension == "app", let identifier = bundle.bundleIdentifier else { return true }
        // Explicit development builds have their own identity and location;
        // installing one must never replace the public application.
        if identifier.hasSuffix(".development") { return true }
        let current = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let locations = [URL(fileURLWithPath: "/Applications"), userApplications]
            .map { $0.appendingPathComponent("Local Dictation.app") }
        if locations.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == current }) { return true }
        let existing = locations.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard existing.count <= 1 else {
            explain("Choose one installed copy", "Local Dictation is present in both /Applications and your personal Applications folder. Keep the copy you intend to use, then reopen this app. No copies have been changed.")
            return false
        }
        let freshLocation = locations.first(where: {
            FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path)
        }) ?? userApplications.appendingPathComponent("Local Dictation.app")
        let target = existing.first ?? freshLocation
        if let old = existing.first,
           Bundle(url: old)?.bundleIdentifier != identifier {
            explain("Installation needs attention", "An application with a different identity occupies \(old.path). Choose its location in Finder; this installer will not replace it.")
            return false
        }
        let peers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == identifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard peers.isEmpty else {
            explain("Quit the existing app first", "Another Local Dictation copy is running. Quit it from its microphone menu, then reopen this download. Your installed app has not been changed.")
            return false
        }
        let parent = target.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path), !FileManager.default.isWritableFile(atPath: parent.path) {
            explain("Install using Finder", "The existing installation folder is not writable. Quit Local Dictation, then copy this app to \(target.path) in Finder and open that copy. No second installation has been created.")
            return false
        }
        let alert = NSAlert()
        alert.messageText = existing.isEmpty ? "Install Local Dictation?" : "Update Local Dictation?"
        alert.informativeText = "The app will be installed at \(target.path). Models are verified and stored in Application Support. Permission setup begins only in the installed app."
        alert.addButton(withTitle: "Install & Open"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        installing = true; defer { installing = false }
        let status = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 130),
                              styleMask: [.titled], backing: .buffered, defer: false)
        status.title = "Installing Local Dictation"; status.center()
        let label = NSTextField(wrappingLabelWithString: "Preserving verified models and installing the app…")
        label.frame = NSRect(x: 24, y: 52, width: 382, height: 44)
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 25, width: 382, height: 16))
        spinner.style = .bar; spinner.isIndeterminate = true; spinner.startAnimation(nil)
        status.contentView?.addSubview(label); status.contentView?.addSubview(spinner)
        status.makeKeyAndOrderFront(nil); defer { status.orderOut(nil) }
        do {
            let paths = try RuntimePaths.application(bundle: bundle)
            if let old = existing.first {
                let legacy = old.appendingPathComponent("Contents/Resources/Models")
                try await ModelStore(paths: paths, migrationSources: [legacy]).migrateAvailable()
            }
            let source = bundle.bundleURL
            try await Task.detached(priority: .userInitiated) {
                try AppInstallTransaction.install(source: source, target: target,
                                                  expectedIdentifier: identifier)
            }.value
            try Self.launchAfterExit(target)
            return false
        } catch {
            explain("Installation did not finish", error.localizedDescription + "\nOpen the app location in Finder or retry this download.")
            return false
        }
    }

    private func explain(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    private static func launchAfterExit(_ target: URL) throws {
        // Fixed script, separate positional arguments: paths are never shell code.
        // Waiting avoids Launch Services reopening the still-running DMG copy.
        let launcher = Process(); launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "count=0; while /bin/kill -0 \"$1\" 2>/dev/null; do count=$((count+1)); [ \"$count\" -lt 150 ] || exit 1; /bin/sleep 0.2; done; exec /usr/bin/open \"$2\" --args --setup",
                              "localdictation-open", String(ProcessInfo.processInfo.processIdentifier), target.path]
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice; launcher.standardError = FileHandle.nullDevice
        try launcher.run()
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
