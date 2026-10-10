import Foundation
#if canImport(DictationCore)
import DictationCore
#endif

struct CleanupOutcome: Sendable {
    let text: String
    let fallbackReasons: [String]
    let completedChunks: Int
    let totalChunks: Int
}

/// Cleans bounded, independent source spans. Original spans and their separators
/// remain available until one complete, validated result is ready for delivery.
struct CleanupCoordinator: Sendable {
    struct Limits: Sendable {
        var preferredCharacters = 1_200
        var maximumCharacters = 1_500
        var maximumBytes = 4_000
        var maximumPassageBytes = 128_000
        var maximumRequests = 16
        var totalTimeout: TimeInterval = 45
        var requestTimeout: TimeInterval = 20
    }
    struct Chunk: Sendable {
        let prefix: String
        let source: String
        let canClean: Bool
    }
    struct Passage: Sendable {
        let chunks: [Chunk]
        let suffix: String
    }
    typealias Operation = @Sendable (String, VocabularySnapshot, TimeInterval) async throws -> String
    private let limits: Limits
    private let now: @Sendable () -> TimeInterval
    private let operation: Operation

    init(client: CleanupClient) {
        self.init { source, vocabulary, timeout in
            try await client.clean(source, vocabulary: vocabulary, timeout: timeout)
        }
    }

    /// Injection keeps deadline, cancellation, and fallback tests independent of
    /// model processes and the user's local correction service.
    init(limits: Limits = Limits(), now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         operation: @escaping Operation) {
        self.limits = limits
        self.now = now
        self.operation = operation
    }

    func clean(_ source: String, vocabulary: VocabularySnapshot = .empty,
               onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CleanupOutcome {
        try Task.checkCancellation()
        let vocabulary = try VocabularySnapshot(entries: vocabulary.entries, revision: vocabulary.revision)
        guard source.utf8.count <= limits.maximumPassageBytes else {
            onProgress(1, 1)
            return CleanupOutcome(text: source, fallbackReasons: ["passageTooLong"], completedChunks: 1, totalChunks: 1)
        }
        let deadline = now() + max(0, limits.totalTimeout)
        let passage = Self.split(source, vocabulary: vocabulary, limits: limits)
        let total = passage.chunks.count
        var parts: [String] = [], reasons: [String] = [], requests = 0
        var stopped: String?
        func record(_ reason: String) { if !reasons.contains(reason) { reasons.append(reason) } }
        onProgress(0, total)
        for (index, chunk) in passage.chunks.enumerated() {
            try Task.checkCancellation()
            var result = chunk.source
            let remaining = deadline - now()
            if let stopped { record(stopped) }
            else if !chunk.canClean { record("protectedSpanTooLong") }
            else if remaining <= 0 { stopped = "deadline"; record("deadline") }
            else if requests >= limits.maximumRequests { stopped = "requestLimit"; record("requestLimit") }
            else {
                requests += 1
                do {
                    let timeout = min(limits.requestTimeout, remaining)
                    let requestDeadline = now() + timeout
                    let candidate = try await boundedRequest(chunk.source, vocabulary: vocabulary, timeout: timeout)
                    try Task.checkCancellation()
                    if now() >= deadline || now() >= requestDeadline {
                        stopped = "deadline"; record("deadline")
                        if now() < deadline { record("serviceUnavailable") }
                    } else {
                        result = try CleanupClient.validate(candidate, against: chunk.source, vocabulary: vocabulary)
                    }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    if let error = error as? CleanupError {
                        switch error {
                        case .invalidResponse, .truncatedResponse, .unrelatedResponse, .changedProtectedText, .inputTooLong, .emptyInput:
                            record("validationRejected")
                        case .timedOut:
                            stopped = "deadline"; record("deadline")
                            // Expiring the whole passage is normal fallback. A
                            // request that times out while passage budget remains
                            // also asks the app to recover its correction service.
                            if now() < deadline { record("serviceUnavailable") }
                        default:
                            stopped = "serviceUnavailable"; record("serviceUnavailable")
                        }
                    } else {
                        stopped = "serviceUnavailable"; record("serviceUnavailable")
                    }
                }
            }
            parts.append(chunk.prefix + result)
            try Task.checkCancellation()
            onProgress(index + 1, total)
        }
        let assembled = parts.joined() + passage.suffix
        try Task.checkCancellation()
        if assembled != source {
            do { try CleanupClient.validateAssembled(assembled, against: source, vocabulary: vocabulary) }
            catch {
                try Task.checkCancellation()
                record("assemblyRejected")
                return CleanupOutcome(text: source, fallbackReasons: reasons, completedChunks: total, totalChunks: total)
            }
        }
        try Task.checkCancellation()
        return CleanupOutcome(text: assembled, fallbackReasons: reasons, completedChunks: total, totalChunks: total)
    }

    private func boundedRequest(_ source: String, vocabulary: VocabularySnapshot, timeout: TimeInterval) async throws -> String {
        guard timeout.isFinite, timeout > 0 else { throw CleanupError.timedOut }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation(source, vocabulary, timeout) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CleanupError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CleanupError.timedOut }
            try Task.checkCancellation()
            return value
        }
    }

    static func split(_ source: String, vocabulary: VocabularySnapshot = .empty, limits: Limits = Limits()) -> Passage {
        let text = source as NSString
        let all = NSRange(location: 0, length: text.length)
        let words = try! NSRegularExpression(pattern: "\\S+").matches(in: source, range: all).map(\.range)
        guard let first = words.first, let last = words.last else { return Passage(chunks: [], suffix: source) }
        func substring(_ range: NSRange) -> String { text.substring(with: range) }
        func fits(_ value: String) -> Bool { value.count <= limits.maximumCharacters && value.utf8.count <= limits.maximumBytes }
        let fullRange = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let full = substring(fullRange)
        if fits(full) {
            return Passage(chunks: [Chunk(prefix: substring(NSRange(location: 0, length: first.location)), source: full, canClean: true)],
                           suffix: substring(NSRange(location: NSMaxRange(last), length: text.length - NSMaxRange(last))))
        }
        var protected = CleanupClient.literalRanges(in: source)
        func protect(_ pattern: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            protected += regex.matches(in: source, range: all).map(\.range)
        }
        // Keep multiword quantities, names, and saved aliases intact. Individual
        // identifiers/URLs/paths are already indivisible whitespace tokens.
        let number = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|[0-9]+(?:[.,:][0-9]+)*)"
        protect("\\b\(number)(?:[ \\t-]+(?:\(number)|and))*\\b", options: .caseInsensitive)
        protect("\\b\\p{Lu}[\\p{L}\\p{M}]+(?:[ \\t]+\\p{Lu}[\\p{L}\\p{M}]+)+\\b")
        for entry in vocabulary.entries {
            for form in [entry.preferredSpelling] + entry.aliases {
                let pattern = form.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[^\\S\\r\\n]+")
                protect("(?<![\\p{L}\\p{N}_])\(pattern)(?![\\p{L}\\p{N}_])", options: .caseInsensitive)
            }
        }
        // A local correction and its nearby context must belong to one request.
        // Numeric/name ranges above extend this window to whole phrases. If the
        // resulting indivisible span is too large, it is retained as dictated.
        let markers = try! NSRegularExpression(pattern: "\\b(?:sorry|actually|correction|no|i[ \\t]+mean|make[ \\t]+that|scratch[ \\t]+that)\\b", options: .caseInsensitive)
        func firstWord(endingAfter offset: Int) -> Int {
            var low = 0, high = words.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(words[middle]) <= offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        for marker in markers.matches(in: source, range: all) {
            let index = min(words.count - 1, firstWord(endingAfter: marker.range.location))
            let start = max(0, index - 8), end = min(words.count - 1, index + 9)
            protected.append(NSRange(location: words[start].location, length: NSMaxRange(words[end]) - words[start].location))
        }
        var blocked = [Bool](repeating: false, count: max(0, words.count - 1))
        for range in protected {
            let start = firstWord(endingAfter: range.location)
            guard start < words.count else { continue }
            var end = start
            while end + 1 < words.count, words[end + 1].location < NSMaxRange(range) { end += 1 }
            if start < end { for index in start..<end { blocked[index] = true } }
        }
        var groups: [NSRange] = [], index = 0
        while index < words.count {
            let start = index
            while index < blocked.count, blocked[index] { index += 1 }
            groups.append(NSRange(location: words[start].location, length: NSMaxRange(words[index]) - words[start].location))
            index += 1
        }
        var chunks: [Chunk] = [], group = 0, previousEnd = 0
        while group < groups.count {
            let start = groups[group].location
            var endGroup = group, preferredEnd: Int?, niceEnd: Int?
            while endGroup < groups.count {
                let value = substring(NSRange(location: start, length: NSMaxRange(groups[endGroup]) - start))
                guard fits(value) else { break }
                if value.count <= max(1, limits.preferredCharacters) {
                    preferredEnd = endGroup
                    let next = endGroup + 1 < groups.count ? groups[endGroup + 1].location : text.length
                    let separator = substring(NSRange(location: NSMaxRange(groups[endGroup]), length: next - NSMaxRange(groups[endGroup])))
                    if value.count >= max(1, limits.preferredCharacters / 2),
                       separator.contains("\n") || value.last.map({ ".!?;,".contains($0) }) == true { niceEnd = endGroup }
                }
                endGroup += 1
            }
            let chosen = niceEnd ?? preferredEnd ?? group
            let range = NSRange(location: start, length: NSMaxRange(groups[chosen]) - start)
            let value = substring(range)
            chunks.append(Chunk(prefix: substring(NSRange(location: previousEnd, length: start - previousEnd)), source: value, canClean: fits(value)))
            previousEnd = NSMaxRange(range)
            group = chosen + 1
        }
        return Passage(chunks: chunks, suffix: substring(NSRange(location: previousEnd, length: text.length - previousEnd)))
    }
}
