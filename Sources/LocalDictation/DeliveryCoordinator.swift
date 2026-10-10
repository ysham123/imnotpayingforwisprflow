import Foundation

/// Keeps each staged clipboard item alive until its receiver read window ends.
/// A later recording may start while a delivery owns the clipboard; only its
/// eventual delivery waits. Cancellation never releases an already sent paste.
@MainActor
final class DeliveryCoordinator {
    private var active = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var hasPendingDelivery: Bool { active }

    func acquire() async throws {
        try Task.checkCancellation()
        if active {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            active = true
        }
        // A canceled queued request takes and immediately relinquishes its
        // turn. It cannot stage text or strand another delivery's continuation.
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    func release() {
        if waiting.isEmpty { active = false }
        else { waiting.removeFirst().resume() }
    }

    func waitUntilFinished() async {
        while active {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
                    continuation.resume()
                }
            }
        }
    }
}

/// Orders restoration so an unchanged-content check happens before any focus
/// mutation. The check barrier also stops user-interrupted or canceled work at
/// each asynchronous boundary. Operations are injected for headless testing.
@MainActor
enum DestinationRestoration {
    static func prepare<T>(
        _ target: T,
        check: () throws -> Void,
        validateCurrent: (T) async throws -> Void,
        validateOriginal: (T) async throws -> Void,
        activate: () async throws -> Void,
        restore: (T) async throws -> T
    ) async throws -> T {
        func barrier() throws { try Task.checkCancellation(); try check() }
        try barrier()
        do {
            try await validateCurrent(target)
            try barrier()
            return target
        } catch {
            try barrier()
        }
        try await validateOriginal(target)
        try barrier()
        try await activate()
        try barrier()
        let restored = try await restore(target)
        try barrier()
        try await validateCurrent(restored)
        try barrier()
        return restored
    }
}
