import Foundation
import CryptoKit
import Darwin

private actor Attempts {
    var count = 0
    func next() -> Int { count += 1; return count }
    func value() -> Int { count }
}

@main
struct RuntimeSetupSmoke {
    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await modelTests()
            try installTests()
            try atomicInstallTests()
            try signedInstallTest()
            print("Passed 12 model-store, 9 installation transaction, 4 atomic publication, and 1 real ad-hoc signing regression groups")
        } catch { print("FAIL runtime setup: \(error)"); exit(1) }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RuntimeSetupError.message(message) }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func temporary(_ label: String) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("localdictation-" + label + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    static func expectFailure(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw RuntimeSetupError.message("An invalid model operation succeeded")
    }

    @MainActor
    static func modelTests() async throws {
        let root = try temporary("models"); defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("tiny verified model fixture\n".utf8)
        let asset = ModelStore.Asset(path: "speech.bin", label: "Fixture speech", bytes: Int64(payload.count),
                                     sha256: digest(payload), url: URL(string: "https://example.invalid/model"), inlineUTF8: nil)
        let manifest = ModelStore.Manifest(formatVersion: 1, identifier: "fixture-v1", files: [asset])
        func paths(_ name: String) -> RuntimePaths {
            RuntimePaths(resources: root.appendingPathComponent("Resources"), models: root.appendingPathComponent(name))
        }
        let progress: @MainActor (ModelStore.Progress) -> Void = { _ in }
        let attempts = Attempts()
        let downloader: @Sendable (ModelStore.Asset, URL) async throws -> Void = { _, partial in
            _ = await attempts.next(); try payload.write(to: partial)
        }
        let first = ModelStore(paths: paths("fresh"), manifest: manifest, downloader: downloader)
        try await first.prepare(progress: progress)
        try check(try Data(contentsOf: paths("fresh").models.appendingPathComponent(asset.path)) == payload, "Fresh model bytes differ")
        try await first.prepare(progress: progress)
        try check(await attempts.value() == 1, "Verified model was downloaded twice")
        print("PASS verified downloads and subsequent offline reuse")

        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try payload.write(to: legacy.appendingPathComponent(asset.path))
        let migration = ModelStore(paths: paths("migration"), migrationSources: [legacy], manifest: manifest, downloader: downloader)
        try await migration.migrateAvailable()
        try await migration.prepare(progress: progress)
        try check(await attempts.value() == 1, "Matching legacy model downloaded")
        try check(try Data(contentsOf: legacy.appendingPathComponent(asset.path)) == payload, "Migration changed the original model")
        print("PASS verified legacy migration preserves source and avoids network")

        try Data(repeating: 0, count: payload.count).write(to: legacy.appendingPathComponent(asset.path))
        let corrupt = ModelStore(paths: paths("corrupt-legacy"), migrationSources: [legacy], manifest: manifest, downloader: downloader)
        try await corrupt.prepare(progress: progress)
        try check(await attempts.value() == 2, "Corrupt legacy model was trusted")
        print("PASS corrupt legacy model is downloaded instead")

        let resumePaths = paths("resume"), resumes = Attempts()
        let resume = ModelStore(paths: resumePaths, manifest: manifest, downloader: { _, partial in
            let attempt = await resumes.next()
            if attempt == 1 { try payload.prefix(5).write(to: partial); throw CancellationError() }
            let previous = try Data(contentsOf: partial)
            guard previous == payload.prefix(5) else { throw RuntimeSetupError.message("Partial bytes were lost") }
            try (previous + payload.dropFirst(5)).write(to: partial)
        })
        try await expectFailure { try await resume.prepare(progress: progress) }
        try await resume.prepare(progress: progress)
        try check(try Data(contentsOf: resumePaths.models.appendingPathComponent(asset.path)) == payload, "Resumed download differs")
        print("PASS interrupted partial download survives retry")

        let retries = Attempts()
        let retry = ModelStore(paths: paths("bad-hash"), manifest: manifest, downloader: { _, partial in
            let attempt = await retries.next()
            try (attempt == 1 ? Data(repeating: 0, count: payload.count) : payload).write(to: partial)
        })
        try await retry.prepare(progress: progress)
        try check(await retries.value() == 2, "Hash mismatch was accepted or not retried")
        print("PASS bad download hash never becomes a usable model")

        let rangePaths = paths("unsupported-range"), ranges = Attempts()
        let rangePartial = rangePaths.models.appendingPathComponent(".downloads/" + asset.sha256 + ".part")
        try FileManager.default.createDirectory(at: rangePartial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.prefix(4).write(to: rangePartial)
        let rangeStore = ModelStore(paths: rangePaths, manifest: manifest, downloader: { _, partial in
            let attempt = await ranges.next()
            if attempt == 1 {
                guard try Data(contentsOf: partial) == payload.prefix(4) else { throw RuntimeSetupError.message("Range prefix lost before resume") }
                throw ModelStore.DownloadFailure.resumeUnsupported
            }
            guard !FileManager.default.fileExists(atPath: partial.path) else { throw RuntimeSetupError.message("Unsupported range retained its stuck partial") }
            try payload.write(to: partial)
        })
        try await rangeStore.prepare(progress: progress)
        try check(await ranges.value() == 2, "Unsupported range was not restarted exactly once")
        print("PASS explicit unsupported range restarts once from zero")

        let inline = ModelStore.Asset(path: "ollama/manifest", label: "Fixture metadata", bytes: Int64(payload.count),
                                     sha256: digest(payload), url: nil, inlineUTF8: String(decoding: payload, as: UTF8.self))
        try await ModelStore(paths: paths("inline"), manifest: .init(formatVersion: 1, identifier: "inline", files: [inline]),
                             downloader: { _, _ in throw RuntimeSetupError.message("Inline metadata attempted network") }).prepare(progress: progress)
        print("PASS pinned inline metadata is published without network")

        let unsafe = ModelStore.Asset(path: "../escape", label: "unsafe", bytes: asset.bytes,
                                      sha256: asset.sha256, url: asset.url, inlineUTF8: nil)
        try await expectFailure { try await ModelStore(paths: paths("unsafe"), manifest: .init(formatVersion: 1, identifier: "unsafe", files: [unsafe]), downloader: downloader).prepare(progress: progress) }
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path), "Manifest escaped its storage directory")
        print("PASS traversal manifest rejected before file creation")

        let symlinkPaths = paths("symlink")
        try FileManager.default.createDirectory(at: symlinkPaths.models, withIntermediateDirectories: false)
        let victim = root.appendingPathComponent("victim"); try payload.write(to: victim)
        try FileManager.default.createSymbolicLink(at: symlinkPaths.models.appendingPathComponent(asset.path), withDestinationURL: victim)
        try await expectFailure { try await ModelStore(paths: symlinkPaths, manifest: manifest, downloader: downloader).prepare(progress: progress) }
        try check(try Data(contentsOf: victim) == payload, "Model leaf symlink modified another file")
        print("PASS model leaf symlink rejected without touching its destination")

        let parentPaths = paths("parent-link"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: parentPaths.models, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parentPaths.models.appendingPathComponent("ollama"), withDestinationURL: outside)
        try await expectFailure { try await ModelStore(paths: parentPaths, manifest: .init(formatVersion: 1, identifier: "parent", files: [inline])).prepare(progress: progress) }
        try check(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Model parent symlink escaped storage")
        print("PASS model parent symlink rejected")

        let overlaps = Attempts()
        let overlap = ModelStore(paths: paths("overlap"), manifest: manifest, downloader: { _, partial in
            _ = await overlaps.next(); try await Task.sleep(nanoseconds: 200_000_000); try payload.write(to: partial)
        })
        let active = Task { try await overlap.prepare(progress: progress) }
        while await overlaps.value() == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        try await expectFailure { try await overlap.prepare(progress: progress) }
        try await active.value
        print("PASS overlapping preparation is rejected without duplicate download")

        let cancels = Attempts()
        let cancelStore = ModelStore(paths: paths("cancel"), manifest: manifest, downloader: { _, partial in
            let attempt = await cancels.next()
            if attempt == 1 { try payload.prefix(4).write(to: partial); try await Task.sleep(nanoseconds: 10_000_000_000) }
            try payload.write(to: partial)
        })
        let cancelled = Task { try await cancelStore.prepare(progress: progress) }
        while await cancels.value() == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        cancelled.cancel()
        try await expectFailure { try await cancelled.value }
        try await cancelStore.prepare(progress: progress)
        print("PASS cancellation releases preparation lock and permits recovery")
    }

    static func installTests() throws {
        let scenarios = ["fresh", "replace", "copy-failure", "stage-failure", "final-failure",
                         "fresh-final-failure", "running-before", "running-during", "source-failure"]
        for scenario in scenarios {
            let root = try temporary("install")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("Source.app"), target = root.appendingPathComponent("Applications/Local Dictation.app")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("new".utf8).write(to: source.appendingPathComponent("new"))
            let old = !["fresh", "fresh-final-failure"].contains(scenario)
            if old {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try Data("old".utf8).write(to: target.appendingPathComponent("old"))
            }
            var checks = 0
            do {
                try AppInstallTransaction.install(source: source, target: target, expectedIdentifier: "fixture",
                    copy: { from, to in
                        if scenario == "copy-failure" { throw RuntimeSetupError.message("copy fault") }
                        try FileManager.default.copyItem(at: from, to: to)
                    }, verify: { app in
                        if scenario == "source-failure", app == source { throw RuntimeSetupError.message("source fault") }
                        if scenario == "stage-failure", app != source, app != target { throw RuntimeSetupError.message("stage fault") }
                        if ["final-failure", "fresh-final-failure"].contains(scenario), app == target { throw RuntimeSetupError.message("final fault") }
                        guard try Data(contentsOf: app.appendingPathComponent("new")) == Data("new".utf8) else { throw RuntimeSetupError.message("incomplete copy") }
                    }, running: {
                        checks += 1
                        return scenario == "running-before" || (scenario == "running-during" && checks > 1)
                    })
                try check(["fresh", "replace"].contains(scenario), "Injected install failure did not occur")
            } catch {
                guard !["fresh", "replace"].contains(scenario) else { throw error }
            }
            if ["fresh", "replace"].contains(scenario) {
                try check(try Data(contentsOf: target.appendingPathComponent("new")) == Data("new".utf8), "Installed app differs")
                try check(!FileManager.default.fileExists(atPath: target.appendingPathComponent("old").path), "Old app remained at target")
            } else if old {
                try check(try Data(contentsOf: target.appendingPathComponent("old")) == Data("old".utf8), "Install failure lost previous app")
            } else { try check(!FileManager.default.fileExists(atPath: target.path), "Failed fresh app was published") }
            let parent = target.deletingLastPathComponent()
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            try check(!leftovers.contains(where: { $0.hasPrefix(".localdictation-stage-") }), "Staging directory leaked")
            print("PASS native installer \(scenario)")
        }
    }

    static func signedInstallTest() throws {
        let root = try temporary("real-signing"); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        let executable = source.appendingPathComponent("Contents/MacOS/LocalDictation")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
        let identifier = "dev.localdictation.installfixture"
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "LocalDictation", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: source.appendingPathComponent("Contents/Info.plist"))
        let resource = source.appendingPathComponent("Contents/Resources/fixture.txt")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("signed resource fixture".utf8).write(to: resource)
        let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", identifier, source.path]
        signer.standardInput = FileHandle.nullDevice; signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        try check(signer.terminationStatus == 0, "Real fixture ad-hoc signing failed")
        let original = try Data(contentsOf: executable)
        let target = root.appendingPathComponent("Applications/Local Dictation.app")
        try AppInstallTransaction.install(source: source, target: target, expectedIdentifier: identifier)
        try check(try Data(contentsOf: target.appendingPathComponent("Contents/MacOS/LocalDictation")) == original,
                  "Native installation changed the signed executable")
        print("PASS real ad-hoc app signature and inline designated requirement survive native installation")
    }

    static func atomicInstallTests() throws {
        for scenario in ["real-swap-rollback", "swap-failure", "rollback-failure", "fresh-target-race"] {
            let root = try temporary("atomic-install"); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("Source.app"), target = root.appendingPathComponent("Applications/Local Dictation.app")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("new".utf8).write(to: source.appendingPathComponent("new"))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: false)
            let fresh = scenario == "fresh-target-race"
            if !fresh {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try Data("old".utf8).write(to: target.appendingPathComponent("old"))
            }
            let originalInode = fresh ? nil : try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
            var stage: URL?, renames = 0, runningChecks = 0, observedRealSwap = false
            do {
                try AppInstallTransaction.install(source: source, target: target, expectedIdentifier: "fixture",
                    copy: { from, to in try FileManager.default.copyItem(at: from, to: to); stage = to },
                    verify: { app in
                        guard try Data(contentsOf: app.appendingPathComponent("new")) == Data("new".utf8) else {
                            throw RuntimeSetupError.message("incomplete copy")
                        }
                        if app == target {
                            guard let stage else { throw RuntimeSetupError.message("missing stage") }
                            try check(try Data(contentsOf: stage.appendingPathComponent("old")) == Data("old".utf8), "Exchange lost the original bundle")
                            let stagedInode = try FileManager.default.attributesOfItem(atPath: stage.path)[.systemFileNumber] as? NSNumber
                            try check(stagedInode == originalInode, "Exchange did not preserve the original bundle inode")
                            observedRealSwap = true
                            throw RuntimeSetupError.message("final verification fault")
                        }
                    }, running: {
                        runningChecks += 1
                        if fresh, runningChecks == 2 {
                            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                            try Data("concurrent".utf8).write(to: target.appendingPathComponent("concurrent"))
                        }
                        return false
                    }, rename: { from, to, flags in
                        renames += 1
                        if scenario == "swap-failure" || (scenario == "rollback-failure" && renames == 2) {
                            throw RuntimeSetupError.message("injected atomic rename failure")
                        }
                        guard renamex_np(from.path, to.path, flags) == 0 else {
                            throw RuntimeSetupError.message("real atomic rename rejected: \(errno)")
                        }
                    })
                throw RuntimeSetupError.message("Atomic failure fixture unexpectedly passed")
            } catch {
                if scenario == "rollback-failure" {
                    try check(error.localizedDescription.contains("previous app is preserved"), "Failed rollback omitted recovery location")
                }
            }
            guard let stage else { throw RuntimeSetupError.message("Fixture never copied staging bundle") }
            if scenario == "rollback-failure" {
                try check(observedRealSwap && renames == 2, "Rollback fault did not follow a real exchange")
                try check(try Data(contentsOf: stage.appendingPathComponent("old")) == Data("old".utf8), "Failed rollback deleted the only previous app")
                try check(try Data(contentsOf: target.appendingPathComponent("new")) == Data("new".utf8), "Failed rollback removed canonical app")
            } else if fresh {
                try check(try Data(contentsOf: target.appendingPathComponent("concurrent")) == Data("concurrent".utf8), "Fresh publication replaced a concurrent app")
                try check(renames == 1, "Fresh publication retried without exclusive protection")
            } else {
                try check(try Data(contentsOf: target.appendingPathComponent("old")) == Data("old".utf8), "Atomic failure lost the previous canonical app")
                let restoredInode = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
                try check(restoredInode == originalInode, "Atomic rollback replaced the original inode")
                try check(scenario == "swap-failure" ? renames == 1 : observedRealSwap && renames == 2,
                          "Expected atomic publication/rollback sequence did not occur")
            }
            if scenario != "rollback-failure" {
                try check(!FileManager.default.fileExists(atPath: stage.deletingLastPathComponent().path), "Finished atomic fixture leaked staging")
            }
            print("PASS native atomic installer \(scenario)")
        }
    }
}
