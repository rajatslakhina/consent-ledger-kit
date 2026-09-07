import XCTest
@testable import ConsentLedger

enum Fixtures {
    static let account: Identifier = "acct-1"
    static let childNode: Identifier = "child"
    static let guardianNode: Identifier = "guardian"
    static let guardian: Identifier = "maya"
    static let otherGuardian: Identifier = "omar"

    static let us: Identifier = "US"
    static let uk: Identifier = "GB"
    static let noLaw: Identifier = "XX-nolaw"

    /// US: 13 minimum for everything, consent below 13 (i.e. never, since 13 is
    /// the floor) except generative which needs consent below 16.
    /// GB: 13 minimum, consent below 16 for chat/UGC/generative.
    /// XX-nolaw: only the app's own baseline (13+, no consent).
    static let policy = JurisdictionPolicy(
        version: 1,
        rules: [
            us: [
                Capability.chat.id: CapabilityRule(minimumAge: 13, guardianConsentBelow: nil),
                Capability.generativeFeatures.id: CapabilityRule(minimumAge: 13, guardianConsentBelow: 16),
                Capability.targetedOffers.id: CapabilityRule(minimumAge: 16, guardianConsentBelow: nil)
            ],
            uk: [
                Capability.chat.id: CapabilityRule(minimumAge: 13, guardianConsentBelow: 16),
                Capability.userGeneratedContent.id: CapabilityRule(minimumAge: 13, guardianConsentBelow: 16),
                Capability.generativeFeatures.id: CapabilityRule(minimumAge: 13, guardianConsentBelow: 18),
                Capability.targetedOffers.id: CapabilityRule(minimumAge: 18, guardianConsentBelow: nil)
            ],
            noLaw: [:]
        ],
        baseline: CapabilityRule(minimumAge: 13, guardianConsentBelow: nil)
    )

    static func stamp(_ wall: Int64, _ logical: UInt32 = 0, node: Identifier = childNode) -> HybridTimestamp {
        HybridTimestamp(wallMilliseconds: wall, logical: logical, node: node)
    }

    static func entry(
        _ sequence: UInt64,
        node: Identifier = childNode,
        at wall: Int64,
        logical: UInt32 = 0,
        _ kind: ConsentEventKind
    ) -> LedgerEntry {
        LedgerEntry(
            id: EntryID(node: node, sequence: sequence),
            account: account,
            timestamp: stamp(wall, logical, node: node),
            kind: kind
        )
    }

    static func signal(_ source: AgeSignalSource, _ bracket: AgeBracket, at wall: Int64) -> AgeSignal {
        AgeSignal(source: source, bracket: bracket, observedAt: stamp(wall))
    }

    static func age(_ bracket: AgeBracket?) -> ReconciledAge {
        ReconciledAge(attested: nil, conservative: bracket, disagreements: [], staleSources: [])
    }
}

/// Zero-time sleeper that records the schedule it was asked for.
final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int64] = []

    var delays: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func sleep(milliseconds: Int64) async {
        record(milliseconds)
    }

    private func record(_ milliseconds: Int64) {
        lock.lock(); recorded.append(milliseconds); lock.unlock()
    }
}

/// A controllable clock.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) { self.value = value }

    var now: Int64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ milliseconds: Int64) {
        lock.lock(); value = value.addingSaturating(milliseconds); lock.unlock()
    }

    var reader: @Sendable () -> Int64 {
        { [self] in self.now }
    }
}
