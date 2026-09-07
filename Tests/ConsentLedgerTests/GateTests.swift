import XCTest
@testable import ConsentLedger

final class GateTests: XCTestCase {
    private let policy = Fixtures.policy
    private let g = Fixtures.guardian

    private func consented(scope: ConsentScope = .all) -> ConsentState {
        var state = ConsentState()
        state.apply(.ageDeclared(.under13), at: Fixtures.stamp(1))
        state.apply(.consentGranted(guardian: g, scope: scope), at: Fixtures.stamp(2))
        return state
    }

    // MARK: Policy resolution

    func testUnknownRegionIsTheMeetOfEveryKnownRule() {
        // targeted-offers: US 16, GB 18 → unknown must be 18.
        XCTAssertEqual(policy.rule(for: Capability.targetedOffers.id, in: nil).minimumAge, 18)
        XCTAssertEqual(policy.rule(for: Capability.targetedOffers.id, in: "FR").minimumAge, 18)
        // generative: US consent<16, GB consent<18 → unknown consent<18.
        XCTAssertEqual(policy.rule(for: Capability.generativeFeatures.id, in: nil).guardianConsentBelow, 18)
        // chat: US no consent, GB consent<16 → unknown consent<16.
        XCTAssertEqual(policy.rule(for: Capability.chat.id, in: nil).guardianConsentBelow, 16)
        // A known region with no rule for a capability gets the baseline, not the meet.
        XCTAssertEqual(policy.rule(for: Capability.targetedOffers.id, in: Fixtures.noLaw), policy.baseline)
    }

    func testMeetIsCommutativeAndIdempotent() {
        let a = CapabilityRule(minimumAge: 13, guardianConsentBelow: nil)
        let b = CapabilityRule(minimumAge: 16, guardianConsentBelow: 18)
        XCTAssertEqual(a.meet(b), b.meet(a))
        XCTAssertEqual(a.meet(a), a)
        XCTAssertEqual(a.meet(b), CapabilityRule(minimumAge: 16, guardianConsentBelow: 18))
        XCTAssertEqual(CapabilityRule(minimumAge: -5, guardianConsentBelow: 999).minimumAge, 0)
        XCTAssertEqual(CapabilityRule(minimumAge: -5, guardianConsentBelow: 999).guardianConsentBelow, AgeBracket.maximumAge)
    }

    func testRemoteUpdateCanOnlyTighten() {
        let loosening = JurisdictionPolicy(
            version: 2,
            rules: [
                Fixtures.us: [Capability.chat.id: CapabilityRule(minimumAge: 0, guardianConsentBelow: nil)],
                "BR": [Capability.chat.id: CapabilityRule(minimumAge: 0, guardianConsentBelow: nil)]
            ],
            baseline: CapabilityRule(minimumAge: 0, guardianConsentBelow: nil)
        )
        let applied = policy.applying(update: loosening)
        XCTAssertEqual(applied.version, 2)
        XCTAssertEqual(applied.rule(for: Capability.chat.id, in: Fixtures.us).minimumAge, 13, "cannot loosen below the binary")
        XCTAssertNil(applied.rules["BR"], "new regions are not recognised remotely")
        XCTAssertEqual(applied.rule(for: Capability.chat.id, in: "BR"), policy.rule(for: Capability.chat.id, in: nil))

        let tightening = JurisdictionPolicy(
            version: 3,
            rules: [Fixtures.us: [Capability.chat.id: CapabilityRule(minimumAge: 16, guardianConsentBelow: 18)]],
            baseline: CapabilityRule(minimumAge: 14, guardianConsentBelow: nil)
        )
        let tightened = applied.applying(update: tightening)
        XCTAssertEqual(tightened.rule(for: Capability.chat.id, in: Fixtures.us).minimumAge, 16)
        XCTAssertEqual(tightened.baseline.minimumAge, 14)
        XCTAssertEqual(tightened.applying(update: loosening).version, 3, "older versions are ignored")
    }

    // MARK: Gate decisions

    func testUnknownAgeIsDeniedEverywhere() {
        for capability in Capability.standardSet {
            for region in [nil, Fixtures.us, Fixtures.uk, Fixtures.noLaw, "ZZ"] as [Identifier?] {
                let decision = CapabilityGate.evaluate(capability, age: Fixtures.age(nil), consent: consented(), region: region, policy: policy)
                XCTAssertEqual(decision, .denied(.ageUnknown), "\(capability.id) in \(String(describing: region))")
            }
        }
    }

    func testBelowMinimumAndAmbiguousAreDenied() throws {
        XCTAssertEqual(
            CapabilityGate.evaluate(.chat, age: Fixtures.age(.under13), consent: consented(), region: Fixtures.us, policy: policy),
            .denied(.belowMinimumAge)
        )
        let straddling = try XCTUnwrap(AgeBracket(lowerBound: 10, upperBound: 15))
        XCTAssertEqual(
            CapabilityGate.evaluate(.chat, age: Fixtures.age(straddling), consent: consented(), region: Fixtures.us, policy: policy),
            .denied(.ageAmbiguous)
        )
    }

    func testConsentPathInUK() {
        let teen = Fixtures.age(.thirteenToFifteen)
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: ConsentState(), region: Fixtures.uk, policy: policy), .denied(.consentRequired))

        var pending = ConsentState()
        pending.apply(.ageDeclared(.thirteenToFifteen), at: Fixtures.stamp(1))
        pending.apply(.consentRequested(guardian: g, scope: .all), at: Fixtures.stamp(2))
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: pending, region: Fixtures.uk, policy: policy), .denied(.consentPending))

        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: consented(), region: Fixtures.uk, policy: policy), .allowed(consentBy: g))
        XCTAssertEqual(
            CapabilityGate.evaluate(.chat, age: teen, consent: consented(scope: .capabilities([Capability.purchases.id])), region: Fixtures.uk, policy: policy),
            .denied(.consentRequired), "consent scoped to another capability does not count"
        )

        var revoked = consented()
        revoked.apply(.consentRevoked(guardian: g, scope: .all), at: Fixtures.stamp(3))
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: revoked, region: Fixtures.uk, policy: policy), .denied(.consentRevoked))

        // 16–17 in the UK needs no consent for chat (threshold 16) but does for generative (threshold 18).
        let older = Fixtures.age(.sixteenToSeventeen)
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: older, consent: ConsentState(), region: Fixtures.uk, policy: policy), .allowed(consentBy: nil))
        XCTAssertEqual(CapabilityGate.evaluate(.generativeFeatures, age: older, consent: ConsentState(), region: Fixtures.uk, policy: policy), .denied(.consentRequired))
    }

    func testSameUserDifferentRegionDifferentAnswer() {
        let teen = Fixtures.age(.thirteenToFifteen)
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: ConsentState(), region: Fixtures.us, policy: policy), .allowed(consentBy: nil))
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: ConsentState(), region: Fixtures.uk, policy: policy), .denied(.consentRequired))
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: ConsentState(), region: nil, policy: policy), .denied(.consentRequired), "unknown region = strictest")
        XCTAssertEqual(CapabilityGate.evaluate(.chat, age: teen, consent: ConsentState(), region: Fixtures.noLaw, policy: policy), .allowed(consentBy: nil), "no-law region = baseline only")
    }

    func testSnapshotFailsClosedForUnlistedCapability() {
        let snapshot = CapabilityGate.snapshot(
            capabilities: [.chat], age: Fixtures.age(.adult), consent: ConsentState(), region: Fixtures.us, policy: policy,
            version: 1, producedAt: Fixtures.stamp(1)
        )
        XCTAssertEqual(snapshot.decision(for: Capability.chat.id), .allowed(consentBy: nil))
        XCTAssertEqual(snapshot.decision(for: Capability.purchases.id), .denied(.ageUnknown))
        let empty = CapabilityGate.snapshot(capabilities: [], age: Fixtures.age(.adult), consent: ConsentState(), region: nil, policy: policy, version: 1, producedAt: Fixtures.stamp(1))
        XCTAssertTrue(empty.decisions.isEmpty)
    }
}
