import AppKit
import ApplicationServices
import Foundation

/// A blocked worker queue models a slow editor without reading a user app or
/// launching a GUI fixture. Canceled requests must not attempt AX inspection.
@main
struct TargetInspectorCancellationSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func main() async {
        do {
            try await queuedCancellation()
            print("PASS queued target captures and validations cancel before AX work")
            try await alreadyCanceledRequest()
            print("PASS already canceled capture does not begin inspection")
            try await destinationCancellation()
            print("PASS input-interrupted and task-canceled restoration skip queued AX mutations")
            print("Passed 3 target-inspector cancellation regression groups")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func queuedCancellation() async throws {
        let queue = DispatchQueue(label: "localdictation.tests.blocked-inspector")
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume(); release.wait() }
        }

        let inspector = TargetInspector(queue: queue)
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let anchor = TextInserter.Anchor(processIdentifier: ProcessInfo.processInfo.processIdentifier,
            focusedLeaf: element, cursorElement: element, selection: CFRange(location: 0, length: 0),
            selectionMarker: nil, epoch: 0, owner: UUID())
        let target = TextInserter.Target(processIdentifier: ProcessInfo.processInfo.processIdentifier,
            focusedElement: element, focusedLeaf: element, role: kAXTextAreaRole,
            selection: CFRange(location: 0, length: 0), selectionMarker: nil,
            selectedText: nil, value: nil, rangeText: nil, webEditor: false)
        var started = 0
        let captures = (0..<20).map { _ in
            Task { @MainActor in
                started += 1
                return try await inspector.inspect(anchor)
            }
        }
        let validations = (0..<20).map { _ in
            Task { @MainActor in
                started += 1
                try await inspector.validate(target)
            }
        }
        while started != 40 { await Task.yield() }
        // The gated serial queue prevents any AX work while the async methods
        // enqueue. Give their executor hops a bounded opportunity to complete.
        try await Task.sleep(nanoseconds: 60_000_000)
        captures.forEach { $0.cancel() }
        validations.forEach { $0.cancel() }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        release.signal()
        for task in captures { try await requireCancellation(task) }
        for task in validations { try await requireCancellation(task) }
        guard ProcessInfo.processInfo.systemUptime - releasedAt < 0.5 else {
            throw Failure(description: "Canceled queue entries delayed later work")
        }

        // Cancellation belongs to each request, never the serial inspector.
        // This invalid target fails before any AX call and proves a fresh
        // request executes normally after the canceled batch drains.
        let invalidTarget = TextInserter.Target(processIdentifier: 0, focusedElement: nil,
            focusedLeaf: nil, role: "unverified", selection: nil, selectionMarker: nil,
            selectedText: nil, value: nil, rangeText: nil, webEditor: false)
        do {
            try await inspector.validate(invalidTarget)
            throw Failure(description: "Unverified fresh target was accepted")
        } catch is CancellationError {
            throw Failure(description: "Canceled request poisoned the next request")
        } catch TextInserter.InsertionError.targetChanged {
            // Expected: the new request reached normal target validation.
        }
    }

    @MainActor
    static func alreadyCanceledRequest() async throws {
        let inspector = TargetInspector()
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let anchor = TextInserter.Anchor(processIdentifier: ProcessInfo.processInfo.processIdentifier,
            focusedLeaf: element, cursorElement: element, selection: CFRange(location: 0, length: 0),
            selectionMarker: nil, epoch: 0, owner: UUID())
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await inspector.inspect(anchor)
        }
        try await requireCancellation(task)
    }

    static func requireCancellation<T: Sendable>(_ task: Task<T, Error>) async throws {
        do {
            _ = try await task.value
            throw Failure(description: "Canceled AX request completed successfully")
        } catch is CancellationError {
            return
        }
    }

    @MainActor
    static func destinationCancellation() async throws {
        let queue = DispatchQueue(label: "localdictation.tests.blocked-restoration")
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume(); release.wait() }
        }
        let inspector = TargetInspector(queue: queue)
        // No element is valid here. Only cancellation can produce the expected
        // error before the normal original-window guard is reached.
        let target = TextInserter.Target(processIdentifier: 0, focusedElement: nil,
            focusedLeaf: nil, role: "unverified", selection: nil, selectionMarker: nil,
            selectedText: nil, value: nil, rangeText: nil, webEditor: false, preserveDestination: true)
        let input = AXRequestCancellation(), taskCancellation = AXRequestCancellation()
        let physical = Task { try await inspector.restoreDestination(target, cancellation: input) }
        let canceled = Task { try await inspector.restoreDestination(target, cancellation: taskCancellation) }
        let validation = Task { try await inspector.validateDestination(target, cancellation: input) }
        try await Task.sleep(nanoseconds: 60_000_000)
        input.cancel() // Mirrors physical input without canceling the Swift task.
        canceled.cancel()
        release.signal()
        try await requireCancellation(physical)
        try await requireCancellation(canceled)
        try await requireCancellation(validation)
        do {
            _ = try await inspector.restoreDestination(target, cancellation: AXRequestCancellation())
            throw Failure(description: "Missing original target was accepted")
        } catch TextInserter.InsertionError.targetChanged { }
    }
}
