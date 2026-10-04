import Foundation

@main struct CleanupLeaseSmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let server = Process()
        server.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        server.arguments = [root.appendingPathComponent("server.py").path, root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        let portFile = root.appendingPathComponent("port")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try String(contentsOf: portFile).trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let lease = CorrectionServiceLease(endpoint: endpoint)
        lease.activate(server)
        let client = CleanupClient(baseURL: endpoint, ownedServiceLease: lease)
        func require(_ condition: Bool, _ message: String = "Cleanup lease assertion failed") { precondition(condition, message) }
        func counts() throws -> [String: Int] {
            let data = try Data(contentsOf: root.appendingPathComponent("counts.json"))
            return try JSONDecoder().decode([String: Int].self, from: data)
        }
        func clean() async throws {
            let result = try await client.clean("Hello.")
            precondition(result == "Hello.")
        }
        try await clean(); try await clean()
        try require(counts()["tags"] == 1 && counts()["show"] == 1, "Owned cache was not used")
        try require(counts()["resident"] == 2, "Owned model was not retained")
        precondition(client.lastTiming?.loadSeconds == 0.001)

        lease.invalidateMetadata(); try await clean()
        try require(counts()["tags"] == 2, "Generation change reused metadata")
        let alternate = CleanupClient(baseURL: endpoint, model: "other:latest", ownedServiceLease: lease)
        _ = try await alternate.clean("Hello.")
        try require(counts()["show"] == 3, "Different model reused metadata")

        try "malformed".write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        do { try await clean(); fatalError("Malformed response accepted") } catch { }
        try "healthy".write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        try await clean()
        try require(counts()["tags"] == 4, "Service error did not invalidate metadata")

        try await client.unloadOwnedModel()
        try require(counts()["unload"] == 1)
        try await clean()
        try require(counts()["tags"] == 5, "Unload did not invalidate metadata")

        let external = CleanupClient(baseURL: endpoint)
        _ = try await external.clean("Hello."); _ = try await external.clean("Hello.")
        try require(counts()["tags"] == 7, "External service acquired cache")
        try await external.unloadOwnedModel()
        try require(counts()["unload"] == 1, "External service was unloaded")

        lease.invalidate()
        try await clean()
        try require(counts()["tags"] == 8, "Stopped lease retained cache")
        try require(counts()["temporary"] == 3, "Unowned requests retained model indefinitely")
        print("Passed 9 owned-service metadata/retention regressions")
    }
}
