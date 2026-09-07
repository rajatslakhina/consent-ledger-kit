import XCTest
@testable import ConsentLedger

final class LedgerTests: XCTestCase {
    private let g = Fixtures.guardian
    private let chat = Capability.chat.id

    // MARK: State machine

    func testConsentBeforeAnyAgeIsRejectedNotApplied() {
        var state = ConsentState()
        state.apply(.consentGranted(guardian: g, scope: .all), at: Fixtures.stamp(1))
        state.apply(.consentRequested(guardian: g, scope: .all), at: Fixtures.stamp(2))
        XCTAssertEqual(state.phase, .unknown)
        XCTAssertEqual(state.rejectedEvents, 2)
        XCTAssertEqual(state.consentStatus(for: chat), .none)
    }

    func testRevocationIsNeverRejected() {
        var state = ConsentState()
        state.apply(.consentRevoked(guardian: g, scope: .all), at: Fixtures.stamp(1))
        XCTAssertEqual(state.rejectedEvents, 0)
        XCTAssertEqual(state.consentStatus(for: chat), .revoked(by: g))
        state.apply(.ageDeclared(.under13), at: Fixtures.stamp(2))
        state.apply(.consentGranted(guardian: g, scope: .all), at: Fixtures.stamp(3))
        XCTAssertEqual(state.consentStatus(for: chat), .granted(by: g), "a later grant by the same guardian re-opens")
    }

    func testHappyPathProgressesThroughPhases() {
        var state = ConsentState()
        state.apply(.ageDeclared(.under13), at: Fixtures.stamp(1))
        XCTAssertEqual(state.phase, .declared)
        state.apply(.ageVerified(.under13, source: .serverAccountAge), at: Fixtures.stamp(2))
        XCTAssertEqual(state.phase, .verified)
        state.apply(.consentRequested(guardian: g, scope: .all), at: Fixtures.stamp(3))
        XCTAssertEqual(state.phase, .consentPending)
        XCTAssertEqual(state.consentStatus(for: chat), .pending(guardian: g))
        state.apply(.consentGranted(guardian: g, scope: .all), at: Fixtures.stamp(4))
        XCTAssertEqual(state.phase, .consentGranted)
        XCTAssertEqual(state.consentStatus(for: chat), .granted(by: g))
        state.apply(.consentRevoked(guardian: g, scope: .all), at: Fixtures.stamp(5))
        XCTAssertEqual(state.phase, .consentRevoked)
        XCTAssertEqual(state.consentStatus(for: chat), .revoked(by: g))
        state.apply(.consentGranted(guardian: g, scope: .all), at: Fixtures.stamp(6))
        XCTAssertEqual(state.phase, .consentGranted, "a later re-grant is honoured")
    }

    func testVerificationNeverDowngradesTrust() {
        var state = ConsentState()
        state.apply(.ageVerified(.under13, source: .guardianAttestation), at: Fixtures.stamp(1))
        state.apply(.ageVerified(.adult, source: .serverAccountAge), at: Fixtures.stamp(2))
        XCTAssertEqual(state.verifiedBracket, .under13)
        XCTAssertEqual(state.verifiedBy, .guardianAttestation)
    }

    func testAnyGuardianRevocationBeatsAnotherGuardianGrant() {
        var state = ConsentState()
        state.apply(.ageDeclared(.under13), at: Fixtures.stamp(1))
        state.apply(.consentGranted(guardian: g, scope: .all), at: Fixtures.stamp(2))
        state.apply(.consentRevoked(guardian: Fixtures.otherGuardian, scope: .capabilities([chat])), at: Fixtures.stamp(3))
        XCTAssertEqual(state.consentStatus(for: chat), .revoked(by: Fixtures.otherGuardian))
        XCTAssertEqual(state.consentStatus(for: Capability.purchases.id), .granted(by: g), "scope is respected")
    }

    // MARK: Ledger merge algebra

    private func ledger(with entries: [LedgerEntry]) throws -> Ledger {
        var ledger = Ledger(account: Fixtures.account)
        try ledger.merge(entries: entries)
        return ledger
    }

    private var sample: [LedgerEntry] {
        [
            Fixtures.entry(1, at: 100, .ageDeclared(.under13)),
            Fixtures.entry(2, at: 200, .consentRequested(guardian: g, scope: .all)),
            Fixtures.entry(1, node: Fixtures.guardianNode, at: 300, .consentGranted(guardian: g, scope: .all)),
            Fixtures.entry(2, node: Fixtures.guardianNode, at: 400, .consentRevoked(guardian: g, scope: .capabilities([chat]))),
            Fixtures.entry(3, at: 500, .ageVerified(.under13, source: .serverAccountAge))
        ]
    }

    func testMergeIsCommutativeAssociativeAndIdempotent() throws {
        let a = try ledger(with: Array(sample[0..<2]))
        let b = try ledger(with: Array(sample[2..<4]))
        let c = try ledger(with: Array(sample[4..<5]))

        var ab = a; try ab.merge(b)
        var ba = b; try ba.merge(a)
        XCTAssertEqual(ab.fold(), ba.fold(), "commutative")

        var abc = ab; try abc.merge(c)
        var bc = b; try bc.merge(c)
        var a_bc = a; try a_bc.merge(bc)
        XCTAssertEqual(abc.fold(), a_bc.fold(), "associative")

        var aa = a; try aa.merge(a); try aa.merge(a)
        XCTAssertEqual(aa.tailCount, a.tailCount, "idempotent")
        XCTAssertEqual(aa.fold(), a.fold())
    }

    func testOutOfOrderDeliveryConverges() throws {
        let inOrder = try ledger(with: sample)
        let reversed = try ledger(with: sample.reversed())
        let shuffled = try ledger(with: [sample[3], sample[0], sample[4], sample[1], sample[2]])
        XCTAssertEqual(inOrder.fold(), reversed.fold())
        XCTAssertEqual(inOrder.fold(), shuffled.fold())
        XCTAssertEqual(inOrder.fold().consentStatus(for: chat), .revoked(by: g))
        XCTAssertEqual(inOrder.fold().consentStatus(for: Capability.purchases.id), .granted(by: g))
    }

    /// Two devices act in the same HLC instant: revoke wins regardless of
    /// which node name sorts first.
    func testConcurrentGrantAndRevokeTieFailsClosed() throws {
        let grant = LedgerEntry(id: EntryID(node: "zzz", sequence: 1), account: Fixtures.account,
                                timestamp: HybridTimestamp(wallMilliseconds: 50, logical: 0, node: "zzz"),
                                kind: .consentGranted(guardian: g, scope: .all))
        let revoke = LedgerEntry(id: EntryID(node: "aaa", sequence: 1), account: Fixtures.account,
                                 timestamp: HybridTimestamp(wallMilliseconds: 50, logical: 0, node: "aaa"),
                                 kind: .consentRevoked(guardian: g, scope: .all))
        let declared = Fixtures.entry(1, at: 1, .ageDeclared(.under13))

        for order in [[declared, grant, revoke], [declared, revoke, grant], [grant, revoke, declared]] {
            let state = try ledger(with: order).fold()
            XCTAssertEqual(state.consentStatus(for: chat), .revoked(by: g), "order \(order.map(\.id.node))")
        }
        // Flip the node names so the revoke's node sorts *after* the grant's.
        let grant2 = LedgerEntry(id: EntryID(node: "aaa", sequence: 1), account: Fixtures.account,
                                 timestamp: HybridTimestamp(wallMilliseconds: 50, logical: 0, node: "aaa"),
                                 kind: .consentGranted(guardian: g, scope: .all))
        let revoke2 = LedgerEntry(id: EntryID(node: "zzz", sequence: 1), account: Fixtures.account,
                                  timestamp: HybridTimestamp(wallMilliseconds: 50, logical: 0, node: "zzz"),
                                  kind: .consentRevoked(guardian: g, scope: .all))
        XCTAssertEqual(try ledger(with: [declared, grant2, revoke2]).fold().consentStatus(for: chat), .revoked(by: g))
    }

    func testForeignAccountEntriesAreRefusedWhole() throws {
        var ledger = Ledger(account: Fixtures.account)
        let foreign = LedgerEntry(id: EntryID(node: "x", sequence: 1), account: "someone-else",
                                  timestamp: Fixtures.stamp(1), kind: .ageDeclared(.adult))
        XCTAssertThrowsError(try ledger.merge(entries: [sample[0], foreign]))
        XCTAssertEqual(ledger.tailCount, 0, "a refused merge leaves the ledger untouched")
    }

    // MARK: Compaction

    func testCompactionFoldsOnlyContiguousPrefixAndStaysConvergent() throws {
        var ledger = Ledger(account: Fixtures.account, limits: .init(compactionThreshold: 2, hardCapacity: 100))
        // Node "child" wrote 1,2,4 (3 is missing); guardian wrote 1.
        try ledger.merge(entries: [
            Fixtures.entry(1, at: 100, .ageDeclared(.under13)),
            Fixtures.entry(2, at: 200, .consentRequested(guardian: g, scope: .all)),
            Fixtures.entry(4, at: 400, .consentRevoked(guardian: g, scope: .all)),
            Fixtures.entry(1, node: Fixtures.guardianNode, at: 300, .consentGranted(guardian: g, scope: .all))
        ])
        let before = ledger.fold()
        XCTAssertTrue(ledger.needsCompaction)
        ledger.compact()
        XCTAssertEqual(ledger.snapshot.watermarks[Fixtures.childNode], 2)
        XCTAssertEqual(ledger.snapshot.watermarks[Fixtures.guardianNode], 1)
        XCTAssertEqual(ledger.tailCount, 1, "seq 4 stays in the tail behind the gap")
        XCTAssertEqual(ledger.fold(), before, "compaction does not change the folded state")

        // The missing entry 3 arrives late with a timestamp *between* folded ones
        // is impossible by contiguity (3 < 4 and 4 is unfolded); a late 3 that
        // sorts after the horizon folds normally.
        try ledger.merge(entries: [Fixtures.entry(3, at: 350, .ageVerified(.under13, source: .serverAccountAge))])
        XCTAssertEqual(ledger.fold().verifiedBracket, .under13)

        // A duplicate of an already-folded entry is dropped, not re-applied.
        try ledger.merge(entries: [Fixtures.entry(1, at: 100, .ageDeclared(.under13))])
        XCTAssertEqual(ledger.tailCount, 2)
    }

    func testCompactionDoesNotFoldPastAnUnfoldableEarlierEntry() throws {
        var ledger = Ledger(account: Fixtures.account, limits: .init(compactionThreshold: 1, hardCapacity: 100))
        // Guardian's seq 2 (no seq 1 seen) sorts *before* child's seq 2.
        try ledger.merge(entries: [
            Fixtures.entry(1, at: 100, .ageDeclared(.under13)),
            Fixtures.entry(2, node: Fixtures.guardianNode, at: 150, .consentGranted(guardian: g, scope: .all)),
            Fixtures.entry(2, at: 200, .consentRevoked(guardian: g, scope: .all))
        ])
        ledger.compact()
        XCTAssertEqual(ledger.snapshot.watermarks[Fixtures.childNode], 1, "only child seq 1 (t=100) is before the gap")
        XCTAssertEqual(ledger.tailCount, 2)
        // Now guardian seq 1 arrives; it must still fold in order.
        try ledger.merge(entries: [Fixtures.entry(1, node: Fixtures.guardianNode, at: 120, .consentRequested(guardian: g, scope: .all))])
        XCTAssertEqual(ledger.fold().consentStatus(for: chat), .revoked(by: g))
        ledger.compact()
        XCTAssertEqual(ledger.tailCount, 0)
        XCTAssertEqual(ledger.fold().consentStatus(for: chat), .revoked(by: g))
    }

    func testEntryPredatingSnapshotFromUnknownNodeIsRefused() throws {
        var ledger = Ledger(account: Fixtures.account, limits: .init(compactionThreshold: 1, hardCapacity: 100))
        try ledger.merge(entries: [
            Fixtures.entry(1, at: 100, .ageDeclared(.under13)),
            Fixtures.entry(2, at: 200, .consentRequested(guardian: g, scope: .all))
        ])
        ledger.compact()
        XCTAssertEqual(ledger.tailCount, 0)
        let late = Fixtures.entry(1, node: "phantom", at: 50, .consentGranted(guardian: g, scope: .all))
        XCTAssertThrowsError(try ledger.merge(entries: [late])) { error in
            XCTAssertEqual(error as? LedgerError, .entryPredatesSnapshot(late.id))
        }
    }

    func testHardCapacityRefusesMergeAndLeavesLedgerIntact() throws {
        var ledger = Ledger(account: Fixtures.account, limits: .init(compactionThreshold: 1, hardCapacity: 3))
        try ledger.merge(entries: [Fixtures.entry(1, at: 1, .ageDeclared(.under13))])
        let flood = (2...10).map { Fixtures.entry(UInt64($0), at: Int64($0), .consentRequested(guardian: g, scope: .all)) }
        XCTAssertThrowsError(try ledger.merge(entries: flood)) { error in
            guard case .capacityExceeded(let tail, let cap)? = error as? LedgerError else { return XCTFail("\(error)") }
            XCTAssertEqual(tail, 10)
            XCTAssertEqual(cap, 3)
        }
        XCTAssertEqual(ledger.tailCount, 1)
        XCTAssertEqual(Ledger.Limits(compactionThreshold: 10, hardCapacity: 2).hardCapacity, 10, "cap never below threshold")
    }

    // MARK: Account merge

    func testAbsorbKeepsRevocationsFromBothAccountsAndIsIdempotent() throws {
        var main = Ledger(account: Fixtures.account)
        try main.merge(entries: [
            Fixtures.entry(1, at: 1_000, .ageDeclared(.under13)),
            Fixtures.entry(2, at: 2_000, .consentGranted(guardian: g, scope: .all))
        ])
        var guest = Ledger(account: "guest", limits: .init(compactionThreshold: 1, hardCapacity: 100))
        let guestNode: Identifier = "guest-dev"
        try guest.merge(entries: [
            LedgerEntry(id: EntryID(node: guestNode, sequence: 1), account: "guest",
                        timestamp: Fixtures.stamp(500, node: guestNode), kind: .ageDeclared(.under13)),
            LedgerEntry(id: EntryID(node: guestNode, sequence: 2), account: "guest",
                        timestamp: Fixtures.stamp(2_500, node: guestNode),
                        kind: .consentRevoked(guardian: Fixtures.otherGuardian, scope: .capabilities([chat])))
        ])
        guest.compact() // the guest's revocation now lives only in its snapshot
        XCTAssertEqual(guest.tailCount, 0)

        let marker = Fixtures.entry(3, at: 3_000, .accountMerged(from: "guest"))
        try main.absorb(guest, mergedAt: marker)
        let state = main.fold()
        XCTAssertEqual(state.mergedAccounts, ["guest"])
        XCTAssertEqual(state.consentStatus(for: chat), .revoked(by: Fixtures.otherGuardian), "revocation survived the merge")
        XCTAssertEqual(state.consentStatus(for: Capability.purchases.id), .granted(by: g))

        let tailBefore = main.tailCount
        try main.absorb(guest, mergedAt: marker)
        XCTAssertEqual(main.tailCount, tailBefore, "absorbing twice adds nothing")
        XCTAssertEqual(main.fold(), state)
    }

    func testAbsorbRejectsMismatchedMarker() throws {
        var main = Ledger(account: Fixtures.account)
        let guest = Ledger(account: "guest")
        let wrong = Fixtures.entry(1, at: 1, .accountMerged(from: "not-guest"))
        XCTAssertThrowsError(try main.absorb(guest, mergedAt: wrong))
    }

    func testSyntheticEntriesCompactWithoutBlockingRealOnes() throws {
        var main = Ledger(account: Fixtures.account, limits: .init(compactionThreshold: 1, hardCapacity: 100))
        try main.merge(entries: [Fixtures.entry(1, at: 1_000, .ageDeclared(.under13))])
        var guest = Ledger(account: "guest", limits: .init(compactionThreshold: 1, hardCapacity: 100))
        try guest.merge(entries: [
            LedgerEntry(id: EntryID(node: "gd", sequence: 1), account: "guest", timestamp: Fixtures.stamp(10, node: "gd"), kind: .ageDeclared(.under13)),
            LedgerEntry(id: EntryID(node: "gd", sequence: 2), account: "guest", timestamp: Fixtures.stamp(20, node: "gd"), kind: .consentRevoked(guardian: g, scope: .all))
        ])
        guest.compact()
        try main.absorb(guest, mergedAt: Fixtures.entry(2, at: 2_000, .accountMerged(from: "guest")))
        XCTAssertTrue(main.tail.keys.contains { $0.isSynthetic })
        let folded = main.fold()
        main.compact()
        XCTAssertEqual(main.tailCount, 0, "synthetic entries fold and leave the tail")
        XCTAssertEqual(main.fold(), folded)
        XCTAssertFalse(main.snapshot.foldedSynthetic.isEmpty)
        // Re-absorbing after compaction is a no-op because the synthetic IDs are covered.
        try main.absorb(guest, mergedAt: Fixtures.entry(2, at: 2_000, .accountMerged(from: "guest")))
        XCTAssertEqual(main.tailCount, 0)
    }

    /// The guest-then-sign-in case: both accounts were written by the *same*
    /// device, so both ledgers' real entries start at `(node, 1)`. Re-homing
    /// under the original ID would overwrite the signed-in account's entries.
    func testAbsorbFromSameNodeDoesNotCollideWithOwnEntries() throws {
        var main = Ledger(account: Fixtures.account)
        try main.merge(entries: [
            Fixtures.entry(1, at: 1_000, .ageDeclared(.thirteenToFifteen)),
            Fixtures.entry(2, at: 2_000, .consentGranted(guardian: g, scope: .all))
        ])
        var guest = Ledger(account: "guest")
        try guest.merge(entries: [
            LedgerEntry(id: EntryID(node: Fixtures.childNode, sequence: 1), account: "guest",
                        timestamp: Fixtures.stamp(500), kind: .ageDeclared(.under13)),
            LedgerEntry(id: EntryID(node: Fixtures.childNode, sequence: 2), account: "guest",
                        timestamp: Fixtures.stamp(600), kind: .consentRevoked(guardian: Fixtures.otherGuardian, scope: .capabilities([chat])))
        ])
        let report = try main.absorb(guest, mergedAt: Fixtures.entry(3, at: 3_000, .accountMerged(from: "guest")))
        XCTAssertEqual(report.imported, 3)
        XCTAssertEqual(report.grantsDropped, 0)
        XCTAssertEqual(main.tailCount, 5, "two own entries + two re-homed + marker; nothing overwritten")
        XCTAssertNotNil(main.tail[EntryID(node: Fixtures.childNode, sequence: 1)])
        XCTAssertNotNil(main.tail[EntryID(node: Fixtures.childNode, sequence: 2)])
        let state = main.fold()
        XCTAssertEqual(state.consentStatus(for: chat), .revoked(by: Fixtures.otherGuardian))
        XCTAssertEqual(state.consentStatus(for: Capability.purchases.id), .granted(by: g))
        XCTAssertEqual(state.declaredBracket, .thirteenToFifteen, "main's later declaration wins on timestamp")
    }

    /// Once this ledger has compacted past the guest's history, grants that
    /// predate the horizon are dropped and revocations move to the merge
    /// instant. The gate can only get more closed.
    func testAbsorbPastCompactionHorizonIsFailClosedNotAnError() throws {
        var main = Ledger(account: Fixtures.account, limits: .init(compactionThreshold: 1, hardCapacity: 100))
        try main.merge(entries: [
            Fixtures.entry(1, at: 5_000, .ageDeclared(.thirteenToFifteen)),
            Fixtures.entry(2, at: 6_000, .consentRevoked(guardian: g, scope: .capabilities([Capability.purchases.id])))
        ])
        main.compact()
        XCTAssertEqual(main.snapshot.horizon, Fixtures.stamp(6_000))

        var guest = Ledger(account: "guest")
        try guest.merge(entries: [
            LedgerEntry(id: EntryID(node: "gd", sequence: 1), account: "guest", timestamp: Fixtures.stamp(1_000, node: "gd"), kind: .ageDeclared(.under13)),
            // A guest grant of *everything* by the same guardian, older than the horizon.
            LedgerEntry(id: EntryID(node: "gd", sequence: 2), account: "guest", timestamp: Fixtures.stamp(2_000, node: "gd"), kind: .consentGranted(guardian: g, scope: .all)),
            LedgerEntry(id: EntryID(node: "gd", sequence: 3), account: "guest", timestamp: Fixtures.stamp(3_000, node: "gd"), kind: .consentRevoked(guardian: Fixtures.otherGuardian, scope: .capabilities([chat])))
        ])
        let report = try main.absorb(guest, mergedAt: Fixtures.entry(3, at: 7_000, .accountMerged(from: "guest")))
        XCTAssertEqual(report.grantsDropped, 1, "a grant cannot be moved later in history")
        XCTAssertEqual(report.revocationsRetimestamped, 1)
        XCTAssertEqual(report.otherDropped, 1, "the guest's age declaration predates the horizon")
        let state = main.fold()
        XCTAssertEqual(state.consentStatus(for: Capability.purchases.id), .revoked(by: g), "the folded revocation is not re-opened by the older guest grant")
        XCTAssertEqual(state.consentStatus(for: chat), .revoked(by: Fixtures.otherGuardian), "the guest's revocation still lands")
        XCTAssertEqual(state.mergedAccounts, ["guest"])

        // Idempotent even after re-timestamping: IDs derive from the original stamps.
        let tail = main.tailCount
        try main.absorb(guest, mergedAt: Fixtures.entry(3, at: 7_000, .accountMerged(from: "guest")))
        XCTAssertEqual(main.tailCount, tail)
    }

    func testAbsorbRefusesTimestampsOutsideSyntheticRange() throws {
        var main = Ledger(account: Fixtures.account)
        var guest = Ledger(account: "guest")
        try guest.merge(entries: [
            LedgerEntry(id: EntryID(node: "gd", sequence: 1), account: "guest",
                        timestamp: HybridTimestamp(wallMilliseconds: Int64.max, logical: 0, node: "gd"), kind: .ageDeclared(.under13))
        ])
        XCTAssertThrowsError(try main.absorb(guest, mergedAt: Fixtures.entry(1, at: 1, .accountMerged(from: "guest")))) { error in
            guard case .syntheticIdentityExhausted? = error as? LedgerError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(main.tailCount, 0)
    }

    // MARK: Codable round trip

    func testLedgerRoundTripsThroughJSON() throws {
        var ledger = Ledger(account: Fixtures.account, limits: .init(compactionThreshold: 1, hardCapacity: 50))
        try ledger.merge(entries: sample)
        ledger.compact()
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(Ledger.self, from: data)
        XCTAssertEqual(decoded, ledger)
        XCTAssertEqual(decoded.fold(), ledger.fold())
    }
}
