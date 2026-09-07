import Foundation

// MARK: - Saturating arithmetic

/// Every counter in this module that can grow without bound goes through these
/// helpers instead of raw `+`/`*`. A trap on overflow inside a consent gate is a
/// crash in the one place the app is legally required to keep working.
extension FixedWidthInteger {
    @inlinable
    public func addingSaturating(_ other: Self) -> Self {
        let (value, overflow) = addingReportingOverflow(other)
        if overflow { return other < 0 ? Self.min : Self.max }
        return value
    }

    @inlinable
    public func subtractingSaturating(_ other: Self) -> Self {
        let (value, overflow) = subtractingReportingOverflow(other)
        if overflow { return other > 0 ? Self.min : Self.max }
        return value
    }

    @inlinable
    public func multipliedSaturating(by other: Self) -> Self {
        let (value, overflow) = multipliedReportingOverflow(by: other)
        if overflow {
            let negative = (self < 0) != (other < 0)
            return negative ? Self.min : Self.max
        }
        return value
    }
}

// MARK: - Identifiers

/// A validated, wire-safe identifier. Every string that crosses a device or
/// server boundary in this module (device IDs, account IDs, guardian IDs,
/// capability IDs, region codes) is an `Identifier`, validated on construction
/// *and* on decode so a malformed payload is rejected at the edge rather than
/// stored into the ledger.
///
/// Allowed: `[A-Za-z0-9._-]`, 1…64 characters.
public struct Identifier: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public static let maximumLength = 64

    public let rawValue: String

    /// The only way to build an `Identifier` from a runtime string. Labelled
    /// so that a string *literal* cannot silently pick this overload (or the
    /// literal one) by accident: literals use `ExpressibleByStringLiteral`,
    /// runtime strings use this, and the two never compete.
    public init?(validating rawValue: String) {
        guard Identifier.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard Identifier.isValid(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Identifier '\(raw.prefix(80))' violates [A-Za-z0-9._-]{1,\(Identifier.maximumLength)}"
            )
        }
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func isValid(_ raw: String) -> Bool {
        let scalars = raw.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maximumLength else { return false }
        for scalar in scalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-":
                continue
            default:
                return false
            }
        }
        return true
    }

    public static func < (lhs: Identifier, rhs: Identifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }

    /// The value a malformed *literal* collapses to. It is itself a valid,
    /// ordinary identifier — not a sentinel the gate treats specially — and
    /// it exists so that `Identifier` literals need no force-unwrap. Any
    /// module that writes literals should assert none of them equal this
    /// (see `PrimitiveTests.testCanonicalCapabilitiesExist`).
    public static let malformedLiteral = Identifier(unchecked: "malformed-literal")

    private init(unchecked: String) {
        self.rawValue = unchecked
    }
}

/// Compile-time literals (`let node: Identifier = "child-ipad"`) validate at
/// runtime like any other input and collapse to `malformedLiteral` when
/// invalid. Runtime strings must go through the failable `init?(validating:)`.
extension Identifier: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = Identifier(validating: value) ?? .malformedLiteral
    }
}

// MARK: - Wall clock

public enum WallClock {
    /// Milliseconds since the Unix epoch, without the `Int64(Double)` trap:
    /// a non-finite or out-of-range interval clamps instead of crashing.
    public static func nowMilliseconds(_ date: Date = Date()) -> Int64 {
        milliseconds(fromSeconds: date.timeIntervalSince1970)
    }

    public static func milliseconds(fromSeconds seconds: Double) -> Int64 {
        let scaled = seconds * 1000
        if scaled.isNaN { return 0 }
        if scaled >= Double(Int64.max) { return Int64.max }
        if scaled <= Double(Int64.min) { return Int64.min }
        return Int64(scaled.rounded(.down))
    }
}

// MARK: - Hybrid logical clock

/// A hybrid logical timestamp: wall-clock milliseconds, a logical counter that
/// disambiguates events inside the same millisecond, and the node that issued
/// it. The tuple is totally ordered, which is what lets every replica fold the
/// same set of ledger entries into the same state regardless of arrival order.
///
/// Why not plain wall-clock time: two devices (a child's iPad and a guardian's
/// iPhone) have independently drifting clocks, and "the guardian's revocation
/// happened after the grant" must be decided the same way on both devices. HLC
/// keeps timestamps close to wall time for humans and audits, while `receive`
/// guarantees causality: anything a node emits after seeing a remote timestamp
/// sorts after it.
public struct HybridTimestamp: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// Milliseconds since the Unix epoch. `Int64` on every platform so the
    /// wire format does not change between a 32-bit and a 64-bit `Int`.
    public let wallMilliseconds: Int64
    public let logical: UInt32
    public let node: Identifier

    public init(wallMilliseconds: Int64, logical: UInt32, node: Identifier) {
        self.wallMilliseconds = wallMilliseconds
        self.logical = logical
        self.node = node
    }

    public static func < (lhs: HybridTimestamp, rhs: HybridTimestamp) -> Bool {
        if lhs.wallMilliseconds != rhs.wallMilliseconds { return lhs.wallMilliseconds < rhs.wallMilliseconds }
        if lhs.logical != rhs.logical { return lhs.logical < rhs.logical }
        return lhs.node < rhs.node
    }

    public var description: String { "\(wallMilliseconds).\(logical)@\(node)" }
}

/// The per-node clock that issues `HybridTimestamp`s. A value type: the owner
/// (an actor) is responsible for serialising `tick`/`receive`.
public struct HybridClock: Sendable, Equatable {
    public let node: Identifier
    public private(set) var lastWall: Int64
    public private(set) var lastLogical: UInt32

    public init(node: Identifier) {
        self.node = node
        self.lastWall = 0
        self.lastLogical = 0
    }

    /// Issues a timestamp for a local event.
    public mutating func tick(nowMilliseconds now: Int64) -> HybridTimestamp {
        if now > lastWall {
            lastWall = now
            lastLogical = 0
        } else {
            advanceLogical()
        }
        return HybridTimestamp(wallMilliseconds: lastWall, logical: lastLogical, node: node)
    }

    /// Folds a remote timestamp into the local clock so that every timestamp
    /// issued afterwards sorts after it.
    public mutating func receive(_ remote: HybridTimestamp, nowMilliseconds now: Int64) {
        let candidateWall = max(lastWall, remote.wallMilliseconds, now)
        if candidateWall == lastWall, candidateWall == remote.wallMilliseconds {
            lastLogical = max(lastLogical, remote.logical)
            advanceLogical()
        } else if candidateWall == lastWall {
            advanceLogical()
        } else if candidateWall == remote.wallMilliseconds {
            lastWall = candidateWall
            lastLogical = remote.logical
            advanceLogical()
        } else {
            lastWall = candidateWall
            lastLogical = 0
        }
    }

    /// The logical counter is 32 bits; exhausting it inside one millisecond is
    /// not realistic, but "not realistic" is not "impossible", so on saturation
    /// the clock advances the wall component by one millisecond instead of
    /// wrapping (which would break ordering) or trapping.
    private mutating func advanceLogical() {
        if lastLogical == UInt32.max {
            lastWall = lastWall.addingSaturating(1)
            lastLogical = 0
        } else {
            lastLogical += 1
        }
    }
}
