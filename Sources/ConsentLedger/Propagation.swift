import Foundation

// MARK: - Propagation

public enum PropagationError: Error, Hashable, Sendable {
    /// The server already holds a newer snapshot for this account. Not a
    /// failure to retry — the local snapshot is simply superseded.
    case staleVersion(server: HybridTimestamp, offered: HybridTimestamp)
    /// Transport failure; retryable.
    case transport(String)
}

public struct PropagationAck: Hashable, Sendable {
    public let accepted: HybridTimestamp
    public init(accepted: HybridTimestamp) { self.accepted = accepted }
}

/// The seam to the backend feature-flag / remote-config system. The contract
/// is monotone on `GateSnapshot.producedAt` (an HLC timestamp, totally
/// ordered across devices): the server must reject a snapshot older than the
/// one it holds, so two devices publishing concurrently converge on the
/// newest rather than the last-to-arrive. A per-device counter would not do
/// — two devices both publishing "version 3" is exactly the collision that
/// makes last-writer-wins silently wrong.
public protocol GatePropagator: Sendable {
    func publish(_ snapshot: GateSnapshot, account: Identifier) async throws -> PropagationAck
}

/// Bounded retry with an injectable sleeper, so tests run the schedule in
/// zero wall time. Retries transport errors only; a stale version is final.
public struct RetryPolicy: Sendable, Equatable {
    public var maximumAttempts: Int
    public var backoffMilliseconds: [Int64]

    public init(maximumAttempts: Int, backoffMilliseconds: [Int64]) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.backoffMilliseconds = backoffMilliseconds
    }

    public static let standard = RetryPolicy(maximumAttempts: 4, backoffMilliseconds: [250, 1_000, 4_000])

    /// Bounds-checked: past the end of the schedule, the last value repeats;
    /// an empty schedule means no delay.
    public func delay(beforeAttempt attempt: Int) -> Int64 {
        guard attempt >= 1, !backoffMilliseconds.isEmpty else { return 0 }
        let index = min(attempt - 1, backoffMilliseconds.count - 1)
        return backoffMilliseconds[index]
    }
}

public protocol Sleeper: Sendable {
    func sleep(milliseconds: Int64) async
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(milliseconds: Int64) async {
        guard milliseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(milliseconds).multipliedSaturating(by: 1_000_000))
    }
}

/// An in-memory stand-in for the backend. Also the reference implementation
/// of the monotone contract: a lower version is rejected with `staleVersion`.
public actor InMemoryGateServer: GatePropagator {
    public private(set) var latest: [Identifier: GateSnapshot] = [:]
    public private(set) var publishCount = 0
    private var failNextPublishes: Int = 0

    public init() {}

    /// Makes the next `count` publishes fail with a transport error.
    public func failNext(_ count: Int) { failNextPublishes = max(0, count) }

    public func publish(_ snapshot: GateSnapshot, account: Identifier) async throws -> PropagationAck {
        publishCount = publishCount.addingSaturating(1)
        if failNextPublishes > 0 {
            failNextPublishes -= 1
            throw PropagationError.transport("simulated outage")
        }
        if let current = latest[account], current.producedAt >= snapshot.producedAt {
            throw PropagationError.staleVersion(server: current.producedAt, offered: snapshot.producedAt)
        }
        latest[account] = snapshot
        return PropagationAck(accepted: snapshot.producedAt)
    }

    public func snapshot(for account: Identifier) -> GateSnapshot? { latest[account] }
}
