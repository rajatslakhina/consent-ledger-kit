import XCTest
@testable import ConsentLedger

/// Negative controls. Each audit is run against the shipped implementation
/// (must pass) *and* against a deliberately broken one (must fail). A test
/// that only checks the shipped side would still pass if the audit were an
/// empty function.
final class AuditTests: XCTestCase {
    private let g = Fixtures.guardian

    private var contentious: [LedgerEntry] {
        // A grant and a revoke for the same guardian, plus the age they hang
        // off — the minimum set where arrival order changes the answer.
        [
            Fixtures.entry(1, at: 100, .ageDeclared(.under13)),
            Fixtures.entry(1, node: Fixtures.guardianNode, at: 200, .consentGranted(guardian: g, scope: .all)),
            Fixtures.entry(2, node: Fixtures.guardianNode, at: 300, .consentRevoked(guardian: g, scope: .all)),
            Fixtures.entry(2, at: 400, .consentRequested(guardian: Fixtures.otherGuardian, scope: .all))
        ]
    }

    func testConvergenceAuditPassesShippedFold() throws {
        let report = try XCTUnwrap(ConvergenceAudit.check(contentious, strategy: ConvergenceAudit.shippedFold))
        XCTAssertEqual(report.permutationsChecked, 24)
        XCTAssertTrue(report.converged)
        XCTAssertEqual(report.distinctOutcomes, 1)
    }

    func testConvergenceAuditRejectsArrivalOrderFold() throws {
        let report = try XCTUnwrap(ConvergenceAudit.check(contentious, strategy: ConvergenceAudit.arrivalOrderFold))
        XCTAssertEqual(report.permutationsChecked, 24)
        XCTAssertFalse(report.converged, "arrival-order folding must be caught")
        XCTAssertGreaterThan(report.distinctOutcomes, 1)
    }

    func testConvergenceAuditAlsoCatchesAWrongTieBreak() throws {
        // Same instant, grant vs revoke. A fold that orders by node name
        // instead of by kind gives a different answer depending on the names.
        let byNodeOnly: ConvergenceAudit.FoldStrategy = { entries in
            var state = ConsentState()
            for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
                state.apply(entry.kind, at: entry.timestamp)
            }
            return state
        }
        let tie: [LedgerEntry] = [
            Fixtures.entry(1, at: 1, .ageDeclared(.under13)),
            LedgerEntry(id: EntryID(node: "a", sequence: 1), account: Fixtures.account,
                        timestamp: HybridTimestamp(wallMilliseconds: 9, logical: 0, node: "a"), kind: .consentRevoked(guardian: g, scope: .all)),
            LedgerEntry(id: EntryID(node: "b", sequence: 1), account: Fixtures.account,
                        timestamp: HybridTimestamp(wallMilliseconds: 9, logical: 0, node: "b"), kind: .consentGranted(guardian: g, scope: .all))
        ]
        // Node-only ordering *does* converge (it is total) — but to the wrong
        // answer: the grant (node "b") applies last and wins.
        let wrong = try XCTUnwrap(ConvergenceAudit.check(tie, strategy: byNodeOnly))
        XCTAssertTrue(wrong.converged)
        XCTAssertEqual(byNodeOnly(tie).consentStatus(for: Capability.chat.id), .granted(by: g))
        // The shipped fold converges to the fail-closed answer.
        XCTAssertEqual(ConvergenceAudit.shippedFold(tie).consentStatus(for: Capability.chat.id), .revoked(by: g))
    }

    func testConvergenceAuditBoundsItsInput() {
        XCTAssertNil(ConvergenceAudit.check([], strategy: ConvergenceAudit.shippedFold))
        let tooMany = (1...8).map { Fixtures.entry(UInt64($0), at: Int64($0), .ageDeclared(.under13)) }
        XCTAssertNil(ConvergenceAudit.check(tooMany, strategy: ConvergenceAudit.shippedFold))
        var count = 0
        ConvergenceAudit.forEachPermutation(of: [1, 2, 3]) { _ in count += 1 }
        XCTAssertEqual(count, 6)
        ConvergenceAudit.forEachPermutation(of: [Int]()) { _ in XCTFail("no permutations of nothing") }
    }

    func testFailClosedAuditPassesShippedGateAndRejectsOptimisticGate() {
        let shipped = FailClosedAudit.check(policy: Fixtures.policy, capabilities: Capability.standardSet, evaluator: FailClosedAudit.shippedEvaluator)
        XCTAssertTrue(shipped.isEmpty, "\(shipped)")

        let broken = FailClosedAudit.check(policy: Fixtures.policy, capabilities: Capability.standardSet, evaluator: FailClosedAudit.optimisticEvaluator)
        XCTAssertFalse(broken.isEmpty)
        XCTAssertTrue(broken.allSatisfy { $0.scenario == "unknown age" })
        // 5 capabilities × (nil + 3 known regions + 1 unlisted) = 25 unknown-age violations.
        XCTAssertEqual(broken.count, 25)
        XCTAssertTrue(broken.contains { $0.region == nil })
        XCTAssertTrue(broken.contains { $0.region?.rawValue == "ZZ-unlisted" })
    }

    func testFailClosedAuditCatchesAConsentBypass() {
        let bypass: FailClosedAudit.Evaluator = { capability, age, consent, region, policy in
            let decision = CapabilityGate.evaluate(capability, age: age, consent: consent, region: region, policy: policy)
            if decision == .denied(.consentRequired) { return .allowed(consentBy: nil) } // "we'll ask later"
            return decision
        }
        let violations = FailClosedAudit.check(policy: Fixtures.policy, capabilities: Capability.standardSet, evaluator: bypass)
        XCTAssertFalse(violations.isEmpty)
        XCTAssertTrue(violations.allSatisfy { $0.scenario == "consent required, none given" })
        XCTAssertTrue(violations.contains { $0.capability == Capability.chat.id && $0.region == Fixtures.uk })
    }
}
