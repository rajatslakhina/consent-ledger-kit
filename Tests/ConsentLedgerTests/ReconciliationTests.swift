import XCTest
@testable import ConsentLedger

final class ReconciliationTests: XCTestCase {
    private let now: Int64 = 10_000_000
    private let policy = ReconciliationPolicy.standard

    func testNoSignalsIsUnknown() {
        let result = AgeSignalReconciler.reconcile([], policy: policy, nowMilliseconds: now)
        XCTAssertNil(result.conservative)
        XCTAssertNil(result.attested)
        XCTAssertFalse(result.isKnown)
    }

    func testLatestPerSourceIgnoresOlderArrivalRegardlessOfOrder() {
        let old = Fixtures.signal(.declaredRange, .under13, at: 1_000)
        let new = Fixtures.signal(.declaredRange, .thirteenToFifteen, at: 2_000)
        XCTAssertEqual(AgeSignalReconciler.latestPerSource([old, new])[.declaredRange], new)
        XCTAssertEqual(AgeSignalReconciler.latestPerSource([new, old])[.declaredRange], new)
    }

    func testAgreementIntersects() throws {
        let declared = Fixtures.signal(.declaredRange, try XCTUnwrap(AgeBracket(lowerBound: 10, upperBound: 15)), at: now)
        let server = Fixtures.signal(.serverAccountAge, try XCTUnwrap(AgeBracket(lowerBound: 13, upperBound: nil)), at: now)
        let result = AgeSignalReconciler.reconcile([declared, server], policy: policy, nowMilliseconds: now)
        XCTAssertEqual(result.conservative?.lowerBound, 13)
        XCTAssertEqual(result.conservative?.upperBound, 15)
        XCTAssertEqual(result.attested?.source, .serverAccountAge)
        XCTAssertTrue(result.disagreements.isEmpty)
    }

    /// The load-bearing rule: disagreement never makes the child older.
    func testDisagreementFallsToYoungestBracketEvenWhenHigherTrustSaysOlder() {
        let device = Fixtures.signal(.declaredRange, .under13, at: now)
        let server = Fixtures.signal(.serverAccountAge, .adult, at: now)
        let result = AgeSignalReconciler.reconcile([device, server], policy: policy, nowMilliseconds: now)
        XCTAssertEqual(result.attested?.source, .serverAccountAge, "UI shows the higher-trust source")
        XCTAssertEqual(result.conservative, .under13, "the gate uses the youngest bracket")
        XCTAssertEqual(result.disagreements.count, 1)
        XCTAssertEqual(result.disagreements.first?.higherTrust.source, .serverAccountAge)
        XCTAssertEqual(result.disagreements.first?.lowerTrust.source, .declaredRange)
    }

    func testDisagreementIsOrderIndependent() {
        let device = Fixtures.signal(.declaredRange, .under13, at: now)
        let server = Fixtures.signal(.serverAccountAge, .adult, at: now)
        let a = AgeSignalReconciler.reconcile([device, server], policy: policy, nowMilliseconds: now)
        let b = AgeSignalReconciler.reconcile([server, device], policy: policy, nowMilliseconds: now)
        XCTAssertEqual(a, b)
    }

    func testGuardianAttestationResolvesDisputeUpwards() {
        let device = Fixtures.signal(.declaredRange, .under13, at: now)
        let server = Fixtures.signal(.serverAccountAge, .thirteenToFifteen, at: now)
        let guardian = Fixtures.signal(.guardianAttestation, .thirteenToFifteen, at: now)
        let result = AgeSignalReconciler.reconcile([device, server, guardian], policy: policy, nowMilliseconds: now)
        XCTAssertEqual(result.conservative, .thirteenToFifteen)
        XCTAssertEqual(result.attested?.source, .guardianAttestation)
        XCTAssertEqual(result.disagreements.count, 1, "the device disagreement is still reported")
    }

    func testStaleSignalDoesNotOpenAGateButIsReported() {
        let staleServer = Fixtures.signal(.serverAccountAge, .adult, at: now - policy.maximumAgeMilliseconds[.serverAccountAge, default: 0] - 1)
        let freshDevice = Fixtures.signal(.declaredRange, .under13, at: now)
        let result = AgeSignalReconciler.reconcile([staleServer, freshDevice], policy: policy, nowMilliseconds: now)
        XCTAssertEqual(result.conservative, .under13)
        XCTAssertEqual(result.staleSources, [.serverAccountAge])
        XCTAssertTrue(result.disagreements.isEmpty, "a stale source is not a party to a dispute")

        let onlyStale = AgeSignalReconciler.reconcile([staleServer], policy: policy, nowMilliseconds: now)
        XCTAssertNil(onlyStale.conservative)
    }

    func testSignalFromTheFutureIsNotFresh() {
        let future = Fixtures.signal(.declaredRange, .adult, at: now + 1)
        let result = AgeSignalReconciler.reconcile([future], policy: policy, nowMilliseconds: now)
        XCTAssertNil(result.conservative)
        XCTAssertEqual(result.staleSources, [.declaredRange])
    }

    func testFreshnessArithmeticSaturatesAtExtremes() {
        let ancient = Fixtures.signal(.declaredRange, .adult, at: Int64.min)
        XCTAssertFalse(policy.isFresh(ancient, nowMilliseconds: Int64.max))
        XCTAssertFalse(policy.isFresh(Fixtures.signal(.declaredRange, .adult, at: Int64.max), nowMilliseconds: Int64.min))
    }

    func testSourceWithoutFreshnessBudgetIsNeverFresh() {
        let restrictive = ReconciliationPolicy(maximumAgeMilliseconds: [.guardianAttestation: 10])
        let device = Fixtures.signal(.declaredRange, .adult, at: now)
        XCTAssertFalse(restrictive.isFresh(device, nowMilliseconds: now))
    }
}
