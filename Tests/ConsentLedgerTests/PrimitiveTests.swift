import XCTest
@testable import ConsentLedger

final class PrimitiveTests: XCTestCase {

    // MARK: Saturating arithmetic

    func testSaturatingAddAndMultiplyNeverTrap() {
        XCTAssertEqual(Int64.max.addingSaturating(1), Int64.max)
        XCTAssertEqual(Int64.min.addingSaturating(-1), Int64.min)
        XCTAssertEqual(Int64.min.subtractingSaturating(1), Int64.min)
        XCTAssertEqual(Int64.max.subtractingSaturating(-1), Int64.max)
        XCTAssertEqual(UInt64.max.multipliedSaturating(by: 2), UInt64.max)
        XCTAssertEqual(Int64.max.multipliedSaturating(by: -2), Int64.min)
        XCTAssertEqual(Int.max.multipliedSaturating(by: 0), 0)
        XCTAssertEqual((7 as Int).addingSaturating(5), 12)
    }

    func testWallClockClampsNonFiniteAndOutOfRange() {
        XCTAssertEqual(WallClock.milliseconds(fromSeconds: .nan), 0)
        XCTAssertEqual(WallClock.milliseconds(fromSeconds: .infinity), Int64.max)
        XCTAssertEqual(WallClock.milliseconds(fromSeconds: -.infinity), Int64.min)
        XCTAssertEqual(WallClock.milliseconds(fromSeconds: 1e30), Int64.max)
        XCTAssertEqual(WallClock.milliseconds(fromSeconds: 1.5), 1500)
        XCTAssertEqual(WallClock.milliseconds(fromSeconds: 1.9999), 1999)
    }

    // MARK: Identifier

    func testIdentifierRejectsMalformedInput() {
        XCTAssertNil(Identifier(validating: ""))
        XCTAssertNil(Identifier(validating: "has space"))
        XCTAssertNil(Identifier(validating: "emoji-🙂"))
        XCTAssertNil(Identifier(validating: String(repeating: "a", count: 65)))
        XCTAssertNotNil(Identifier(validating: String(repeating: "a", count: 64)))
        XCTAssertNotNil(Identifier(validating: "acct.child_001-x"))
    }

    func testIdentifierValidatesOnDecode() throws {
        let bad = Data("\"not valid!\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Identifier.self, from: bad))
        let good = Data("\"ok-1\"".utf8)
        XCTAssertEqual(try JSONDecoder().decode(Identifier.self, from: good).rawValue, "ok-1")
    }

    func testMalformedLiteralCollapsesToDocumentedValue() {
        let bad: Identifier = "bad literal!"
        XCTAssertEqual(bad, .malformedLiteral)
        let good: Identifier = "fine"
        XCTAssertNotEqual(good, .malformedLiteral)
    }

    func testCanonicalCapabilitiesExist() {
        for capability in Capability.standardSet {
            XCTAssertNotEqual(capability.id, .malformedLiteral, "\(capability.displayName) literal is malformed")
        }
        XCTAssertEqual(Set(Capability.standardSet.map(\.id)).count, Capability.standardSet.count, "capability IDs must be unique")
    }

    func testCanonicalBracketsExist() {
        XCTAssertEqual(AgeBracket.under13.lowerBound, 0)
        XCTAssertEqual(AgeBracket.under13.upperBound, 12)
        XCTAssertEqual(AgeBracket.thirteenToFifteen.lowerBound, 13)
        XCTAssertEqual(AgeBracket.thirteenToFifteen.upperBound, 15)
        XCTAssertEqual(AgeBracket.sixteenToSeventeen.lowerBound, 16)
        XCTAssertEqual(AgeBracket.adult.lowerBound, 18)
        XCTAssertNil(AgeBracket.adult.upperBound)
    }

    // MARK: AgeBracket

    func testBracketRejectsNonsense() {
        XCTAssertNil(AgeBracket(lowerBound: -1, upperBound: 5))
        XCTAssertNil(AgeBracket(lowerBound: 10, upperBound: 5))
        XCTAssertNil(AgeBracket(lowerBound: 151, upperBound: nil))
        XCTAssertNil(AgeBracket(lowerBound: 0, upperBound: 151))
        XCTAssertNotNil(AgeBracket(lowerBound: 0, upperBound: 0))
        XCTAssertNotNil(AgeBracket(lowerBound: 150, upperBound: 150))
    }

    func testBracketIntersectionAndCertainty() throws {
        let a = try XCTUnwrap(AgeBracket(lowerBound: 10, upperBound: 15))
        let b = try XCTUnwrap(AgeBracket(lowerBound: 13, upperBound: nil))
        let i = try XCTUnwrap(a.intersection(b))
        XCTAssertEqual(i.lowerBound, 13)
        XCTAssertEqual(i.upperBound, 15)
        XCTAssertNil(AgeBracket.under13.intersection(.adult))
        XCTAssertTrue(AgeBracket.adult.certainlyAtLeast(18))
        XCTAssertFalse(AgeBracket.adult.certainlyBelow(100))
        XCTAssertTrue(AgeBracket.under13.certainlyBelow(13))
        XCTAssertFalse(a.certainlyAtLeast(13))
        XCTAssertFalse(a.certainlyBelow(13))
    }

    // MARK: Hybrid clock

    func testClockIsMonotoneUnderWallClockRegression() {
        var clock = HybridClock(node: Fixtures.childNode)
        let first = clock.tick(nowMilliseconds: 1_000)
        let second = clock.tick(nowMilliseconds: 900) // wall clock went backwards
        let third = clock.tick(nowMilliseconds: 900)
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, third)
        XCTAssertEqual(second.wallMilliseconds, 1_000)
        XCTAssertEqual(second.logical, 1)
        XCTAssertEqual(third.logical, 2)
    }

    func testReceiveMakesLaterTicksSortAfterRemote() {
        var clock = HybridClock(node: Fixtures.childNode)
        let remote = HybridTimestamp(wallMilliseconds: 5_000, logical: 7, node: Fixtures.guardianNode)
        clock.receive(remote, nowMilliseconds: 1_000)
        let next = clock.tick(nowMilliseconds: 1_000)
        XCTAssertGreaterThan(next, remote)
        XCTAssertEqual(next.wallMilliseconds, 5_000)
        XCTAssertEqual(next.logical, 9) // receive bumped to 8, tick to 9

        // Remote in the past does not move the clock backwards.
        var fresh = HybridClock(node: Fixtures.childNode)
        _ = fresh.tick(nowMilliseconds: 9_000)
        fresh.receive(HybridTimestamp(wallMilliseconds: 1, logical: 0, node: Fixtures.guardianNode), nowMilliseconds: 9_000)
        XCTAssertEqual(fresh.tick(nowMilliseconds: 9_000).wallMilliseconds, 9_000)
    }

    func testLogicalCounterSaturationAdvancesWallInsteadOfWrapping() {
        var clock = HybridClock(node: Fixtures.childNode)
        clock.receive(HybridTimestamp(wallMilliseconds: 100, logical: UInt32.max, node: Fixtures.guardianNode), nowMilliseconds: 100)
        let stamp = clock.tick(nowMilliseconds: 100)
        XCTAssertEqual(stamp.wallMilliseconds, 101)
        XCTAssertLessThan(stamp.logical, 3)
        XCTAssertGreaterThan(stamp, HybridTimestamp(wallMilliseconds: 100, logical: UInt32.max, node: Fixtures.guardianNode))

        var extreme = HybridClock(node: Fixtures.childNode)
        extreme.receive(HybridTimestamp(wallMilliseconds: Int64.max, logical: UInt32.max, node: Fixtures.guardianNode), nowMilliseconds: 0)
        XCTAssertEqual(extreme.tick(nowMilliseconds: 0).wallMilliseconds, Int64.max) // saturates, no trap
    }

    func testTimestampOrderIsTotal() {
        let a = HybridTimestamp(wallMilliseconds: 1, logical: 0, node: "a")
        let b = HybridTimestamp(wallMilliseconds: 1, logical: 0, node: "b")
        let c = HybridTimestamp(wallMilliseconds: 1, logical: 1, node: "a")
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        XCTAssertFalse(a < a)
    }

    // MARK: Retry policy bounds

    func testRetryDelayIsBoundsChecked() {
        let policy = RetryPolicy(maximumAttempts: 10, backoffMilliseconds: [1, 2, 3])
        XCTAssertEqual(policy.delay(beforeAttempt: 0), 0)
        XCTAssertEqual(policy.delay(beforeAttempt: 1), 1)
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 3)
        XCTAssertEqual(policy.delay(beforeAttempt: 99), 3)
        XCTAssertEqual(RetryPolicy(maximumAttempts: 0, backoffMilliseconds: []).delay(beforeAttempt: 5), 0)
        XCTAssertEqual(RetryPolicy(maximumAttempts: 0, backoffMilliseconds: []).maximumAttempts, 1)
    }

    func testSyntheticEntryIDsAreDeterministicAndAboveFloor() {
        let stamp = HybridTimestamp(wallMilliseconds: 1_700_000_000_000, logical: 3, node: "g")
        let a = EntryID.synthetic(for: stamp)
        let b = EntryID.synthetic(for: stamp)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.isSynthetic)
        XCTAssertFalse(EntryID(node: "g", sequence: 1).isSynthetic)
        let other = EntryID.synthetic(for: HybridTimestamp(wallMilliseconds: 1_700_000_000_000, logical: 4, node: "g"))
        XCTAssertNotEqual(a, other)

        // Beyond the packing range the ID is not unique any more; the packing
        // must not trap, and `canSynthesise` must say so, so `absorb` refuses.
        let far = HybridTimestamp(wallMilliseconds: Int64.max, logical: UInt32.max, node: "g")
        XCTAssertLessThanOrEqual(EntryID.synthetic(for: far).sequence, UInt64.max)
        XCTAssertFalse(EntryID.canSynthesise(far))
        XCTAssertFalse(EntryID.canSynthesise(HybridTimestamp(wallMilliseconds: -1, logical: 0, node: "g")))
        XCTAssertFalse(EntryID.canSynthesise(HybridTimestamp(wallMilliseconds: 1, logical: 1 << 20, node: "g")))
        XCTAssertTrue(EntryID.canSynthesise(HybridTimestamp(wallMilliseconds: EntryID.syntheticWallLimit, logical: EntryID.syntheticLogicalMask, node: "g")))
        // Year-2109 ceiling: two distinct in-range stamps never collide.
        let edgeA = EntryID.synthetic(for: HybridTimestamp(wallMilliseconds: EntryID.syntheticWallLimit, logical: 0, node: "g"))
        let edgeB = EntryID.synthetic(for: HybridTimestamp(wallMilliseconds: EntryID.syntheticWallLimit - 1, logical: EntryID.syntheticLogicalMask, node: "g"))
        XCTAssertNotEqual(edgeA, edgeB)
        XCTAssertLessThan(edgeA.sequence, UInt64.max)
    }
}
