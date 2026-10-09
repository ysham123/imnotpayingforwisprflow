import Foundation

private actor Calls {
    private var sources: [String] = []
    private var timeouts: [TimeInterval] = []
    func add(_ source: String, timeout: TimeInterval) -> Int {
        sources.append(source); timeouts.append(timeout); return sources.count
    }
    func count() -> Int { sources.count }
    func budgets() -> [TimeInterval] { timeouts }
}
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func add(_ current: Int, _ total: Int) { lock.lock(); values.append((current, total)); lock.unlock() }
    func read() -> [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

@main struct CleanupCoordinatorSmoke {
    static func cleaned(_ text: String) -> String { text.replacingOccurrences(of: "um ", with: "") }
    static func main() async throws {
        let source = "\n  " + String(repeating: "um we should send the document tomorrow. ", count: 210) + "\r\n\t"
        let plan = CleanupCoordinator.split(source)
        precondition(plan.chunks.count > 1 && plan.chunks.count <= 16)
        precondition(plan.chunks.map { $0.prefix + $0.source }.joined() + plan.suffix == source)
        precondition(plan.chunks.allSatisfy { !$0.canClean || ($0.source.count <= 1_500 && $0.source.utf8.count <= 4_000) })
        let progress = Progress(), calls = Calls()
        let successful = CleanupCoordinator { value, _, timeout in
            _ = await calls.add(value, timeout: timeout)
            return cleaned(value)
        }
        let result = try await successful.clean(source) { progress.add($0, $1) }
        precondition(result.text == cleaned(source) && result.text.utf8.count > 6_000)
        precondition(result.fallbackReasons.isEmpty && result.completedChunks == plan.chunks.count)
        precondition(progress.read().map { $0.0 } == Array(0...plan.chunks.count))
        precondition(progress.read().allSatisfy { $0.1 == plan.chunks.count })
        let successCalls = await calls.count()
        precondition(successCalls == plan.chunks.count)
        print("PASS long assembled validation, exact separators, bounded requests, and honest progress")

        let blank = try await successful.clean(" \n\t")
        precondition(blank.text == " \n\t" && blank.totalChunks == 0)
        let unicode = String(repeating: "café résumé naïve mañana. ", count: 150)
        let unicodePlan = CleanupCoordinator.split(unicode)
        precondition(unicodePlan.chunks.map { $0.prefix + $0.source }.joined() + unicodePlan.suffix == unicode)
        precondition(unicodePlan.chunks.allSatisfy { !$0.canClean || $0.source.utf8.count <= 4_000 })
        for count in [1_499, 1_500, 1_501] {
            let text = String(repeating: "a ", count: count / 2) + (count % 2 == 1 ? "a" : "")
            let split = CleanupCoordinator.split(text)
            precondition(split.chunks.map { $0.prefix + $0.source }.joined() + split.suffix == text)
            precondition(split.chunks.allSatisfy { $0.source.count <= 1_500 })
        }
        print("PASS empty, Unicode, and exact request-limit boundaries")

        let rejectedCalls = Calls()
        let rejecting = CleanupCoordinator { value, _, timeout in
            if await rejectedCalls.add(value, timeout: timeout) == 2 { throw CleanupError.changedProtectedText }
            return cleaned(value)
        }
        let rejected = try await rejecting.clean(source)
        let rejectedExpected = plan.chunks.enumerated().map { index, chunk in chunk.prefix + (index == 1 ? chunk.source : cleaned(chunk.source)) }.joined() + plan.suffix
        precondition(rejected.text == rejectedExpected && rejected.fallbackReasons == ["validationRejected"])
        let rejectionCount = await rejectedCalls.count()
        precondition(rejectionCount == plan.chunks.count)
        print("PASS a rejected middle chunk stays raw while later independent chunks finish")

        let failedCalls = Calls()
        let failing = CleanupCoordinator { value, _, timeout in
            if await failedCalls.add(value, timeout: timeout) == 2 { throw CleanupError.serviceUnavailable }
            return cleaned(value)
        }
        let failed = try await failing.clean(source)
        let prefixOnly = plan.chunks.enumerated().map { index, chunk in chunk.prefix + (index == 0 ? cleaned(chunk.source) : chunk.source) }.joined() + plan.suffix
        precondition(failed.text == prefixOnly && failed.fallbackReasons == ["serviceUnavailable"])
        let failureCount = await failedCalls.count()
        precondition(failureCount == 2)
        print("PASS a service failure preserves accepted prefix and the exact raw remainder")

        var one = CleanupCoordinator.Limits(); one.maximumRequests = 1
        let limitedCalls = Calls()
        let limited = CleanupCoordinator(limits: one) { value, _, timeout in
            _ = await limitedCalls.add(value, timeout: timeout); return cleaned(value)
        }
        let limitedResult = try await limited.clean(source)
        precondition(limitedResult.text == prefixOnly && limitedResult.fallbackReasons == ["requestLimit"])
        let limitedCount = await limitedCalls.count(); precondition(limitedCount == 1)
        print("PASS passage request cap never discards the unprocessed suffix")

        let clock = TestClock(), budgetCalls = Calls()
        let budgeted = CleanupCoordinator(now: { clock.read() }) { value, _, timeout in
            let call = await budgetCalls.add(value, timeout: timeout)
            clock.advance(call < 3 ? 18 : 10)
            return cleaned(value)
        }
        let budgetResult = try await budgeted.clean(source)
        let twoChunks = plan.chunks.enumerated().map { index, chunk in chunk.prefix + (index < 2 ? cleaned(chunk.source) : chunk.source) }.joined() + plan.suffix
        precondition(budgetResult.text == twoChunks && budgetResult.fallbackReasons == ["deadline"])
        let budgets = await budgetCalls.budgets()
        precondition(budgets == [20, 20, 9])
        print("PASS one global budget shrinks request timeout and rejects a late response")

        var short = CleanupCoordinator.Limits(); short.totalTimeout = 0.03
        let slow = CleanupCoordinator(limits: short) { _, _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000); return "Unreachable"
        }
        let began = ProcessInfo.processInfo.systemUptime
        let timed = try await slow.clean(source)
        precondition(timed.text == source && timed.fallbackReasons == ["deadline"])
        precondition(ProcessInfo.processInfo.systemUptime - began < 1)
        print("PASS in-flight deadline cancels cooperative request without waiting for its original timeout")

        var requestLimited = CleanupCoordinator.Limits()
        requestLimited.totalTimeout = 1; requestLimited.requestTimeout = 0.03
        let stalled = CleanupCoordinator(limits: requestLimited) { _, _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000); return "Unreachable"
        }
        let stalledResult = try await stalled.clean(source)
        precondition(stalledResult.text == source)
        precondition(stalledResult.fallbackReasons == ["deadline", "serviceUnavailable"])
        print("PASS a request timeout requests service recovery while aggregate exhaustion does not")

        let cancelCalls = Calls(), canceledProgress = Progress()
        let cancelable = CleanupCoordinator { value, _, timeout in
            _ = await cancelCalls.add(value, timeout: timeout)
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return cleaned(value)
        }
        let pending = Task { try await cancelable.clean(source) { canceledProgress.add($0, $1) } }
        while await cancelCalls.count() == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        pending.cancel()
        do { _ = try await pending.value; fatalError("Canceled cleanup returned a result") }
        catch is CancellationError { }
        precondition(canceledProgress.read().map { $0.0 } == [0])
        print("PASS cancellation propagates and never reports a completed chunk")

        let code = "```swift\n" + String(repeating: "let user_id = 2;\n", count: 180) + "```"
        let protectedSource = "um send this example.\n" + code + "\n\tum keep the identifiers unchanged.\n"
        let protectedPlan = CleanupCoordinator.split(protectedSource)
        precondition(protectedPlan.chunks.contains { !$0.canClean && $0.source.contains(code) })
        let protectedResult = try await successful.clean(protectedSource)
        precondition(protectedResult.text == cleaned(protectedSource))
        precondition(protectedResult.fallbackReasons == ["protectedSpanTooLong"])
        print("PASS oversized code stays intact while surrounding speech is cleaned")

        var small = CleanupCoordinator.Limits(); small.preferredCharacters = 110; small.maximumCharacters = 170
        let repair = "twenty one, no, twenty two"
        for offset in 0..<25 {
            let sentence = String(repeating: "word ", count: offset) + repair + String(repeating: " word", count: 50)
            let split = CleanupCoordinator.split(sentence, limits: small)
            precondition(split.chunks.filter { $0.source.contains(repair) }.count == 1)
            precondition(split.chunks.map { $0.prefix + $0.source }.joined() + split.suffix == sentence)
        }
        let literalSource = "Keep `user_id` in src/app.swift and pass --dry-run to https://example.com/api."
        _ = try CleanupClient.validate(literalSource, against: literalSource)
        for changed in [literalSource.replacingOccurrences(of: "user_id", with: "userId"),
                        literalSource.replacingOccurrences(of: "--dry-run", with: "--dry"),
                        literalSource.replacingOccurrences(of: "app.swift", with: "app.ts")] {
            do { _ = try CleanupClient.validate(changed, against: literalSource); fatalError("Changed literal accepted") }
            catch { }
        }
        _ = try CleanupClient.validate("Visit https://example.com.", against: "Visit https://example.com")
        print("PASS correction-boundary protection and exact coding literals")

        var tiny = CleanupCoordinator.Limits(); tiny.maximumPassageBytes = 4
        let untouched = CleanupCoordinator(limits: tiny) { _, _, _ in fatalError("Oversized passage reached model") }
        let oversize = try await untouched.clean("larger passage")
        precondition(oversize.text == "larger passage" && oversize.fallbackReasons == ["passageTooLong"])
        print("Passed 12 deterministic cleanup coordinator regression groups")
    }
}
