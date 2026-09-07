import XCTest
@testable import ConsentLedger

final class OrchestratorTests: XCTestCase {
    private let g = Fixtures.guardian

    private func makeDevice(
        node: Identifier,
        clock: ManualClock,
        server: GatePropagator,
        providers: [AgeSignalProvider] = [],
        region: Identifier? = Fixtures.uk,
        retry: RetryPolicy = .standard,
        sleeper: Sleeper = RecordingSleeper(),
        limits: Ledger.Limits = .standard
    ) -> ConsentOrchestrator {
        let configuration = OrchestratorConfiguration(
            node: node, account: Fixtures.account, policy: Fixtures.policy, region: region,
            ledgerLimits: limits, retry: retry
        )
        return ConsentOrchestrator(configuration: configuration, providers: providers, propagator: server, sleeper: sleeper, now: clock.reader)
    }

    // MARK: Fail closed by default

    func testFreshDeviceDeniesEverythingBeforeAnyEvaluation() async {
        let clock = ManualClock(1_000_000)
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: InMemoryGateServer())
        for capability in Capability.standardSet {
            let decision = await device.decision(for: capability)
            XCTAssertEqual(decision, .denied(.ageUnknown))
        }
    }

    /// The gate must never answer from a snapshot older than the last
    /// mutation. No `evaluateAndPublish` between the change and the read.
    func testDecisionReflectsEveryMutationWithoutAPublish() async throws {
        let clock = ManualClock(10_000)
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: InMemoryGateServer(), region: Fixtures.uk)
        _ = await device.evaluateAndPublish() // publishes an ageUnknown snapshot; must not be served back
        var decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .denied(.ageUnknown))

        try await device.observe(source: .declaredRange, bracket: .thirteenToFifteen)
        decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .denied(.consentRequired), "observe is reflected")

        try await device.grantConsent(guardian: g, scope: .all)
        decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .allowed(consentBy: g), "grant is reflected")

        try await device.revokeConsent(guardian: g, scope: .all)
        decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .denied(.consentRevoked), "revoke closes the gate on the very next read")

        try await device.grantConsent(guardian: g, scope: .all)
        await device.setRegion(Fixtures.us)
        decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .allowed(consentBy: nil), "region change is reflected (US chat needs no consent)")

        await device.applyPolicyUpdate(JurisdictionPolicy(
            version: 2, rules: [Fixtures.us: [Capability.chat.id: CapabilityRule(minimumAge: 16, guardianConsentBelow: nil)]],
            baseline: Fixtures.policy.baseline
        ))
        decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .denied(.belowMinimumAge), "policy update is reflected")

        // A peer's revocation merged via importEntries closes immediately too.
        await device.setRegion(Fixtures.uk)
        let peerRevoke = LedgerEntry(id: EntryID(node: Fixtures.guardianNode, sequence: 1), account: Fixtures.account,
                                     timestamp: Fixtures.stamp(20_000, node: Fixtures.guardianNode),
                                     kind: .consentRevoked(guardian: Fixtures.otherGuardian, scope: .capabilities([Capability.chat.id])))
        try await device.importEntries([peerRevoke])
        decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .denied(.consentRevoked), "importEntries is reflected")

        // absorb: a guest account whose guardian attested *under 13*. The
        // age evidence must reach the gate, not just the folded state.
        await device.setRegion(Fixtures.us)
        var guest = Ledger(account: "guest")
        try guest.merge(entries: [
            LedgerEntry(id: EntryID(node: "gd", sequence: 1), account: "guest", timestamp: Fixtures.stamp(5_000, node: "gd"),
                        kind: .ageVerified(.under13, source: .guardianAttestation))
        ])
        decision = await device.decision(for: .purchases)
        XCTAssertEqual(decision, .allowed(consentBy: nil), "before the merge, 13–15 clears the US baseline")
        try await device.absorb(guest)
        decision = await device.decision(for: .purchases)
        XCTAssertEqual(decision, .denied(.belowMinimumAge), "absorb feeds the reconciler: the guardian attestation says under 13")

        // refreshSignals: a provider answer is reflected without a publish.
        // (Constructed on a second device so the provider is the only input.)
        let older = ClosureAgeSignalProvider(source: .serverAccountAge) {
            AgeSignal(source: .serverAccountAge, bracket: .adult, observedAt: Fixtures.stamp(9_000, node: "api"))
        }
        let second = makeDevice(node: Fixtures.guardianNode, clock: clock, server: InMemoryGateServer(), providers: [older], region: Fixtures.us)
        _ = await second.evaluateAndPublish()
        var other = await second.decision(for: .purchases)
        XCTAssertEqual(other, .denied(.ageUnknown))
        _ = await second.refreshSignals()
        other = await second.decision(for: .purchases)
        XCTAssertEqual(other, .allowed(consentBy: nil), "refreshSignals is reflected")

        // Time: once the only signal ages past its freshness window, the gate
        // closes with no mutation at all.
        clock.advance(ReconciliationPolicy.standard.maximumAgeMilliseconds[.serverAccountAge, default: 0].addingSaturating(1))
        other = await second.decision(for: .purchases)
        XCTAssertEqual(other, .denied(.ageUnknown), "a stale signal closes the gate by the clock alone")
        let status = await second.status
        XCTAssertEqual(status.age.staleSources, [.serverAccountAge])
        XCTAssertEqual(status.decision(for: Capability.purchases.id), .denied(.ageUnknown), "status.decisions agrees with decision(for:)")
    }

    // MARK: Two devices converge

    func testChildAndGuardianConvergeAfterSyncAndServerHoldsNewest() async throws {
        let clock = ManualClock(1_000_000)
        let server = InMemoryGateServer()
        let child = makeDevice(node: Fixtures.childNode, clock: clock, server: server)
        let guardian = makeDevice(node: Fixtures.guardianNode, clock: clock, server: server)

        try await child.observe(source: .declaredRange, bracket: .thirteenToFifteen)
        try await child.requestConsent(from: g, scope: .all)
        clock.advance(10)
        _ = await child.evaluateAndPublish()
        var status = await child.status
        XCTAssertEqual(status.decision(for: Capability.chat.id), .denied(.consentPending))

        // Guardian device knows nothing yet: it cannot even see an age.
        let guardianBefore = await guardian.status
        XCTAssertNil(guardianBefore.age.conservative)

        // Sync child → guardian, guardian grants, sync back.
        let fromChild = await child.exportEntries()
        try await guardian.importEntries(fromChild)
        let afterImport = await guardian.status
        XCTAssertEqual(afterImport.age.conservative, .thirteenToFifteen, "age evidence travels with the ledger")
        try await guardian.grantConsent(guardian: g, scope: .all)
        let fromGuardian = await guardian.exportEntries()
        try await child.importEntries(fromGuardian)

        clock.advance(10)
        _ = await child.evaluateAndPublish()
        status = await child.status
        XCTAssertEqual(status.decision(for: Capability.chat.id), .allowed(consentBy: g))
        XCTAssertEqual(status.consent.phase, .consentGranted)

        let guardianStatus = await guardian.status
        XCTAssertEqual(guardianStatus.consent, status.consent, "both replicas fold to the same state")

        let held = await server.snapshot(for: Fixtures.account)
        XCTAssertEqual(held?.decision(for: Capability.chat.id), .allowed(consentBy: g))
    }

    func testServerRejectsOlderSnapshotFromSecondDevice() async throws {
        let clock = ManualClock(5_000)
        let server = InMemoryGateServer()
        let child = makeDevice(node: Fixtures.childNode, clock: clock, server: server)
        let guardian = makeDevice(node: Fixtures.guardianNode, clock: clock, server: server)

        // Guardian's clock has raced ahead by importing a far-future timestamp.
        try await guardian.importEntries([Fixtures.entry(1, node: "far", at: 9_000, .ageDeclared(.adult))])
        let ahead = await guardian.evaluateAndPublish()
        guard case .success = ahead else { return XCTFail("\(ahead)") }

        let behind = await child.evaluateAndPublish()
        guard case .failure(let error) = behind, case .staleVersion = error else { return XCTFail("\(behind)") }
        let childStatus = await child.status
        XCTAssertNil(childStatus.lastAcknowledged)
        XCTAssertNil(childStatus.lastPropagationError, "stale is not an error to retry")

        // After the child syncs, its clock has caught up and its publish wins.
        try await child.importEntries(await guardian.exportEntries())
        let caughtUp = await child.evaluateAndPublish()
        guard case .success = caughtUp else { return XCTFail("\(caughtUp)") }
    }

    // MARK: Retry

    func testTransportFailureRetriesWithScheduleAndGivesUp() async throws {
        let clock = ManualClock(1_000)
        let server = InMemoryGateServer()
        let sleeper = RecordingSleeper()
        let retry = RetryPolicy(maximumAttempts: 3, backoffMilliseconds: [10, 20])
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: server, retry: retry, sleeper: sleeper)

        await server.failNext(2)
        let result = await device.evaluateAndPublish()
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(sleeper.delays, [10, 20])
        let awaited1 = await server.publishCount
        XCTAssertEqual(awaited1, 3)

        await server.failNext(10)
        clock.advance(1)
        let exhausted = await device.evaluateAndPublish()
        guard case .failure(.transport) = exhausted else { return XCTFail("\(exhausted)") }
        XCTAssertEqual(sleeper.delays, [10, 20, 10, 20], "maximumAttempts bounds the loop")
        let status = await device.status
        XCTAssertEqual(status.lastPropagationError, "simulated outage")
        XCTAssertEqual(status.decision(for: Capability.chat.id), .denied(.ageUnknown), "local decision unaffected by transport")
    }

    // MARK: Providers

    func testProviderSignalsAreReconciledAndTransportErrorsCollected() async throws {
        let clock = ManualClock(2_000_000)
        struct Boom: Error {}
        let declared = ClosureAgeSignalProvider(source: .declaredRange) {
            AgeSignal(source: .declaredRange, bracket: .under13, observedAt: Fixtures.stamp(2_000_000, node: "sys"))
        }
        let serverAge = ClosureAgeSignalProvider(source: .serverAccountAge) {
            AgeSignal(source: .serverAccountAge, bracket: .adult, observedAt: Fixtures.stamp(2_000_000, node: "api"))
        }
        let broken = ClosureAgeSignalProvider(source: .guardianAttestation) { throw Boom() }
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: InMemoryGateServer(), providers: [declared, serverAge, broken])

        let errors = await device.refreshSignals()
        XCTAssertEqual(errors.count, 1)
        XCTAssertNotNil(errors[.guardianAttestation])
        let status = await device.status
        XCTAssertEqual(status.age.conservative, .under13, "disagreement → youngest")
        XCTAssertEqual(status.age.disagreements.count, 1)
        XCTAssertEqual(status.consent.phase, .verified, "signals were appended to the ledger")
        XCTAssertEqual(status.ledgerTailCount, 2)

        // Polling again with identical signals appends nothing (dedup by timestamp).
        _ = await device.refreshSignals()
        let awaited2 = await device.status.ledgerTailCount
        XCTAssertEqual(awaited2, 2)
    }

    // MARK: Compaction gated on acknowledgement

    func testCompactionRequiresPeerAcknowledgement() async throws {
        let clock = ManualClock(1_000)
        let device = makeDevice(
            node: Fixtures.childNode, clock: clock, server: InMemoryGateServer(),
            limits: .init(compactionThreshold: 2, hardCapacity: 100)
        )
        try await device.observe(source: .declaredRange, bracket: .under13)
        try await device.requestConsent(from: g, scope: .all)
        try await device.requestConsent(from: Fixtures.otherGuardian, scope: .all)
        let awaited3 = await device.status.ledgerTailCount
        XCTAssertEqual(awaited3, 3)
        let awaited4 = await device.compactIfSafe()
        XCTAssertFalse(awaited4, "nothing acknowledged yet")

        let exported = await device.exportEntries()
        await device.acknowledge(Array(exported.map(\.id).prefix(2)))
        let awaited5 = await device.compactIfSafe()
        XCTAssertFalse(awaited5, "partial acknowledgement is not enough")

        await device.acknowledge(exported.map(\.id))
        let awaited6 = await device.compactIfSafe()
        XCTAssertTrue(awaited6)
        let awaited7 = await device.status.ledgerTailCount
        XCTAssertEqual(awaited7, 0)
        let awaited8 = await device.status.consent.phase
        XCTAssertEqual(awaited8, .consentPending, "state survives compaction")
    }

    // MARK: Account merge through the orchestrator

    func testAbsorbGuestLedgerClosesRevokedCapability() async throws {
        let clock = ManualClock(10_000)
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: InMemoryGateServer(), region: Fixtures.uk)
        try await device.observe(source: .declaredRange, bracket: .thirteenToFifteen)
        try await device.grantConsent(guardian: g, scope: .all)
        clock.advance(1)
        _ = await device.evaluateAndPublish()
        let awaited9 = await device.decision(for: .chat)
        XCTAssertEqual(awaited9, .allowed(consentBy: g))

        var guest = Ledger(account: "guest")
        try guest.merge(entries: [
            LedgerEntry(id: EntryID(node: "gd", sequence: 1), account: "guest", timestamp: Fixtures.stamp(9_000, node: "gd"), kind: .ageDeclared(.thirteenToFifteen)),
            LedgerEntry(id: EntryID(node: "gd", sequence: 2), account: "guest", timestamp: Fixtures.stamp(9_500, node: "gd"),
                        kind: .consentRevoked(guardian: Fixtures.otherGuardian, scope: .capabilities([Capability.chat.id])))
        ])
        try await device.absorb(guest)
        clock.advance(1)
        _ = await device.evaluateAndPublish()
        let awaited10 = await device.decision(for: .chat)
        XCTAssertEqual(awaited10, .denied(.consentRevoked))
        let awaited11 = await device.decision(for: .userGeneratedContent)
        XCTAssertEqual(awaited11, .allowed(consentBy: g))
        let awaited12 = await device.status.consent.mergedAccounts
        XCTAssertEqual(awaited12, ["guest"])
    }

    // MARK: Region and policy

    func testRegionChangeAndMonotonePolicyUpdateAffectDecisions() async throws {
        let clock = ManualClock(10_000)
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: InMemoryGateServer(), region: Fixtures.us)
        try await device.observe(source: .declaredRange, bracket: .thirteenToFifteen)
        _ = await device.evaluateAndPublish()
        let awaited13 = await device.decision(for: .chat)
        XCTAssertEqual(awaited13, .allowed(consentBy: nil))

        await device.setRegion(nil)
        clock.advance(1)
        _ = await device.evaluateAndPublish()
        let awaited14 = await device.decision(for: .chat)
        XCTAssertEqual(awaited14, .denied(.consentRequired), "unknown region is strictest")

        await device.setRegion(Fixtures.us)
        await device.applyPolicyUpdate(JurisdictionPolicy(
            version: 99, rules: [Fixtures.us: [Capability.chat.id: CapabilityRule(minimumAge: 16, guardianConsentBelow: nil)]],
            baseline: Fixtures.policy.baseline
        ))
        clock.advance(1)
        _ = await device.evaluateAndPublish()
        let awaited15 = await device.decision(for: .chat)
        XCTAssertEqual(awaited15, .denied(.belowMinimumAge))
        let awaited16 = await device.activePolicy.version
        XCTAssertEqual(awaited16, 99)
    }

    // MARK: Concurrency

    func testConcurrentPublishesMintDistinctIncreasingVersionsAndNeverRegress() async throws {
        let clock = ManualClock(1_000)
        let server = InMemoryGateServer()
        let spy = RecordingPropagator(wrapping: server)
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: spy)
        try await device.observe(source: .declaredRange, bracket: .adult)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { _ = await device.evaluateAndPublish() }
            }
        }
        let published = await spy.published
        XCTAssertEqual(published.count, 16)
        XCTAssertEqual(Set(published.map(\.version)).count, 16, "every publish carried a distinct version")
        XCTAssertEqual(Set(published.map(\.producedAt)).count, 16, "every publish carried a distinct HLC stamp")
        let byVersion = published.sorted { $0.version < $1.version }
        for pair in zip(byVersion, byVersion.dropFirst()) {
            XCTAssertLessThan(pair.0.producedAt, pair.1.producedAt, "version order and HLC order agree")
        }
        let status = await device.status
        XCTAssertEqual(status.lastPublished?.version, 16)
        let held = await server.snapshot(for: Fixtures.account)
        XCTAssertEqual(held?.producedAt, byVersion.last?.producedAt, "the server holds the newest, whichever order acks landed")
    }

    /// The reentrancy contract, tested with a real suspension: publish #1 is
    /// held open by the propagator while the state changes and publish #2
    /// completes. Because #1's snapshot was minted *before* its await, it is
    /// the stale one — the server must reject it, and the local decision must
    /// be #2's. An implementation that evaluated after the await would have
    /// #1 publish the newer state successfully instead.
    func testSnapshotMintedBeforeFirstAwaitSoLaterStateCannotBeOvertakenByEarlierCall() async throws {
        let clock = ManualClock(1_000)
        let server = InMemoryGateServer()
        let gate = HoldingPropagator(wrapping: server)
        let device = makeDevice(node: Fixtures.childNode, clock: clock, server: gate, region: Fixtures.us)

        let first = Task { await device.evaluateAndPublish() } // ageUnknown snapshot, held at the propagator
        await gate.waitUntilHeld()

        try await device.observe(source: .declaredRange, bracket: .adult)
        clock.advance(1)
        let second = await device.evaluateAndPublish()
        guard case .success = second else { return XCTFail("\(second)") }

        await gate.release()
        let firstResult = await first.value
        guard case .failure(.staleVersion) = firstResult else { return XCTFail("stale snapshot must be rejected, got \(firstResult)") }

        let decision = await device.decision(for: .chat)
        XCTAssertEqual(decision, .allowed(consentBy: nil))
        let held = await server.snapshot(for: Fixtures.account)
        XCTAssertEqual(held?.decision(for: Capability.chat.id), .allowed(consentBy: nil))
        let status = await device.status
        XCTAssertNil(status.lastPropagationError, "a stale rejection is not an error")
    }
}
