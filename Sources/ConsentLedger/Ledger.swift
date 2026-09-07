import Foundation

// MARK: - Entries

/// Identity of a ledger entry: the node that wrote it and that node's own
/// monotonically increasing sequence number. Two properties fall out of this:
/// duplicates are detected by value (no UUID table), and a replica can tell
/// whether it has seen *every* entry a node wrote up to some point, which is
/// what makes compaction safe.
public struct EntryID: Hashable, Sendable, Codable, Comparable {
    public let node: Identifier
    public let sequence: UInt64

    public init(node: Identifier, sequence: UInt64) {
        self.node = node
        self.sequence = sequence
    }

    public static func < (lhs: EntryID, rhs: EntryID) -> Bool {
        if lhs.node != rhs.node { return lhs.node < rhs.node }
        return lhs.sequence < rhs.sequence
    }

    /// Sequence numbers at or above this are *synthetic*: minted by
    /// `Ledger.absorb` for entries re-homed from another account. They are
    /// derived from the entry's original timestamp, so two replicas absorbing
    /// the same account mint the same IDs (idempotent merge), and they never
    /// collide with a real node's counter, which starts at 1 and would need
    /// 2⁶³ writes to get here. Re-homing under the *original* `(node,
    /// sequence)` would collide whenever both accounts were written on the
    /// same device — the guest-then-sign-in case this exists for.
    public static let syntheticFloor: UInt64 = 1 << 63

    /// Wall milliseconds are packed above 20 bits of logical counter; 42 bits
    /// of wall time reach the year 2109. Beyond either limit the packing
    /// saturates rather than traps — and `synthetic(for:)` is then no longer
    /// injective, which `Ledger.absorb` detects and reports as
    /// `LedgerError.syntheticIdentityExhausted` instead of silently dropping
    /// a decision.
    static let syntheticWallLimit: Int64 = (1 << 42) - 1
    static let syntheticLogicalMask: UInt32 = 0xF_FFFF

    static func synthetic(for timestamp: HybridTimestamp) -> EntryID {
        let wall = UInt64(clamping: min(max(timestamp.wallMilliseconds, 0), syntheticWallLimit))
        let packed = wall
            .multipliedSaturating(by: 1 << 20)
            .addingSaturating(UInt64(timestamp.logical & syntheticLogicalMask))
        return EntryID(node: timestamp.node, sequence: syntheticFloor.addingSaturating(packed))
    }

    /// Whether `synthetic(for:)` is injective for this timestamp.
    static func canSynthesise(_ timestamp: HybridTimestamp) -> Bool {
        timestamp.wallMilliseconds >= 0
            && timestamp.wallMilliseconds <= syntheticWallLimit
            && timestamp.logical <= syntheticLogicalMask
    }

    public var isSynthetic: Bool { sequence >= EntryID.syntheticFloor }
}

public struct LedgerEntry: Hashable, Sendable, Codable {
    public let id: EntryID
    public let account: Identifier
    public let timestamp: HybridTimestamp
    public let kind: ConsentEventKind

    public init(id: EntryID, account: Identifier, timestamp: HybridTimestamp, kind: ConsentEventKind) {
        self.id = id
        self.account = account
        self.timestamp = timestamp
        self.kind = kind
    }

    /// The fold order. Total, so every replica folds identically.
    static func foldOrder(_ lhs: LedgerEntry, _ rhs: LedgerEntry) -> Bool {
        if lhs.timestamp.wallMilliseconds != rhs.timestamp.wallMilliseconds {
            return lhs.timestamp.wallMilliseconds < rhs.timestamp.wallMilliseconds
        }
        if lhs.timestamp.logical != rhs.timestamp.logical {
            return lhs.timestamp.logical < rhs.timestamp.logical
        }
        if lhs.kind.tieBreakRank != rhs.kind.tieBreakRank {
            return lhs.kind.tieBreakRank < rhs.kind.tieBreakRank
        }
        if lhs.timestamp.node != rhs.timestamp.node {
            return lhs.timestamp.node < rhs.timestamp.node
        }
        return lhs.id < rhs.id
    }
}

// MARK: - Snapshot

/// The compacted prefix of a ledger: a folded state plus, per node, the
/// sequence number up to which *every* entry has been folded in. An entry
/// with `sequence <= watermark[node]` is provably already accounted for and
/// is dropped on merge instead of being double-applied.
public struct LedgerSnapshot: Hashable, Sendable, Codable {
    public let state: ConsentState
    public let watermarks: [Identifier: UInt64]
    /// The timestamp of the newest entry folded into `state`. An entry older
    /// than this that is *not* covered by a watermark cannot be folded in
    /// order any more; see `LedgerError.entryPredatesSnapshot`.
    public let horizon: HybridTimestamp?
    /// Synthetic entries (see `EntryID.syntheticFloor`) are not part of any
    /// node's contiguous sequence, so they are tracked individually once
    /// folded. Bounded by the number of guardian decisions ever absorbed.
    public let foldedSynthetic: Set<EntryID>

    public init(state: ConsentState, watermarks: [Identifier: UInt64], horizon: HybridTimestamp?, foldedSynthetic: Set<EntryID> = []) {
        self.state = state
        self.watermarks = watermarks
        self.horizon = horizon
        self.foldedSynthetic = foldedSynthetic
    }

    public func covers(_ id: EntryID) -> Bool {
        if id.isSynthetic { return foldedSynthetic.contains(id) }
        guard let watermark = watermarks[id.node] else { return false }
        return id.sequence <= watermark
    }
}

// MARK: - Ledger

public enum LedgerError: Error, Hashable, Sendable {
    /// The uncompacted tail would exceed `Limits.hardCapacity`. The ledger is
    /// left untouched: refusing a merge is safe, corrupting a consent log is
    /// not. The owner compacts (after peers have the entries) and retries.
    case capacityExceeded(tail: Int, hardCapacity: Int)
    /// An entry sorts before the compacted horizon and is not covered by a
    /// watermark. Folding it would change history that other replicas have
    /// already compacted. It is reported, not silently applied.
    case entryPredatesSnapshot(EntryID)
    /// The entry belongs to a different account and no merge was declared.
    case foreignAccount(expected: Identifier, actual: Identifier)
    /// An absorbed entry's timestamp is outside the range for which synthetic
    /// IDs are unique (see `EntryID.synthetic(for:)`); absorbing it could
    /// silently discard another decision, so the whole absorb is refused.
    case syntheticIdentityExhausted(HybridTimestamp)
}

/// What `Ledger.absorb` did. Grants that predate this ledger's compaction
/// horizon cannot be folded in order any more and are *dropped*, never
/// re-timestamped: a grant moved later in history could re-open a gate that
/// a folded revocation had closed. Revocations that predate the horizon are
/// re-timestamped to the merge instant instead — moving a "no" later only
/// ever closes gates. The counts are returned so the caller can surface
/// them; a dropped grant is a consent the guardian has to give again.
public struct AbsorbReport: Hashable, Sendable {
    public let imported: Int
    public let revocationsRetimestamped: Int
    public let grantsDropped: Int
    public let otherDropped: Int
}

/// The append-only, mergeable consent log for one account.
///
/// This is a value type with pure `merge`/`fold`, deliberately: the
/// commutativity/associativity/idempotence tests in `LedgerTests` are
/// statements about values, and the actor that owns persistence
/// (`ConsentLedgerStore`) adds nothing to the semantics.
///
/// Merge is set union on `EntryID`; fold is a sort by `LedgerEntry.foldOrder`
/// followed by `ConsentState.apply` — a state-based CRDT whose "state" is
/// the set of entries. Any two replicas that have exchanged entries agree.
public struct Ledger: Hashable, Sendable, Codable {
    public struct Limits: Hashable, Sendable, Codable {
        /// `needsCompaction` turns true when the tail is longer than this.
        public var compactionThreshold: Int
        /// The tail may never exceed this; a merge that would is refused whole.
        public var hardCapacity: Int

        public init(compactionThreshold: Int, hardCapacity: Int) {
            self.compactionThreshold = max(1, compactionThreshold)
            self.hardCapacity = max(self.compactionThreshold, hardCapacity)
        }

        public static let standard = Limits(compactionThreshold: 256, hardCapacity: 4096)
    }

    public let account: Identifier
    public private(set) var snapshot: LedgerSnapshot
    /// Entries not yet compacted, keyed by ID.
    public private(set) var tail: [EntryID: LedgerEntry]
    public let limits: Limits

    public init(account: Identifier, limits: Limits = .standard) {
        self.account = account
        self.snapshot = LedgerSnapshot(state: ConsentState(), watermarks: [:], horizon: nil)
        self.tail = [:]
        self.limits = limits
    }

    public var tailCount: Int { tail.count }

    // MARK: Append / merge

    /// Appends a locally-authored entry.
    public mutating func append(_ entry: LedgerEntry) throws {
        try merge(entries: [entry])
    }

    /// Merges entries from another replica of the *same* account.
    public mutating func merge(entries: [LedgerEntry]) throws {
        var candidate = self
        for entry in entries {
            guard entry.account == account else {
                throw LedgerError.foreignAccount(expected: account, actual: entry.account)
            }
            if candidate.snapshot.covers(entry.id) { continue }
            if let horizon = candidate.snapshot.horizon, entry.timestamp < horizon {
                throw LedgerError.entryPredatesSnapshot(entry.id)
            }
            candidate.tail[entry.id] = entry
        }
        try candidate.enforceCapacity()
        self = candidate
    }

    /// Merges a whole replica of the same account.
    public mutating func merge(_ other: Ledger) throws {
        try merge(entries: Array(other.tail.values))
    }

    /// Absorbs another *account's* ledger — the account-merge case. Every
    /// fact from the other ledger (its compacted snapshot's age facts and
    /// guardian decisions, plus its uncompacted tail) is re-homed under this
    /// account with a synthetic, timestamp-derived identity, an
    /// `accountMerged` marker is appended, and the fold takes the union.
    /// Revocations in either ledger survive by construction.
    ///
    /// If this ledger has already compacted past some of the other's
    /// history, see `AbsorbReport` for the fail-closed rule applied.
    @discardableResult
    public mutating func absorb(_ other: Ledger, mergedAt marker: LedgerEntry) throws -> AbsorbReport {
        guard marker.account == account, case .accountMerged(let from) = marker.kind, from == other.account else {
            throw LedgerError.foreignAccount(expected: account, actual: marker.account)
        }
        var facts: [(timestamp: HybridTimestamp, kind: ConsentEventKind)] = []
        let otherState = other.snapshot.state
        if let bracket = otherState.declaredBracket, let at = otherState.declaredAt {
            facts.append((at, .ageDeclared(bracket)))
        }
        if let bracket = otherState.verifiedBracket, let source = otherState.verifiedBy, let at = otherState.verifiedAt {
            facts.append((at, .ageVerified(bracket, source: source)))
        }
        for decision in otherState.decisions.values.flatMap(\.allDecisions) {
            let kind: ConsentEventKind = decision.isGranted
                ? .consentGranted(guardian: decision.guardian, scope: decision.scope)
                : .consentRevoked(guardian: decision.guardian, scope: decision.scope)
            facts.append((decision.decidedAt, kind))
        }
        for entry in other.tail.values {
            facts.append((entry.timestamp, entry.kind))
        }

        var imported: [LedgerEntry] = []
        var retimestamped = 0
        var grantsDropped = 0
        var otherDropped = 0
        for fact in facts {
            guard EntryID.canSynthesise(fact.timestamp) else {
                throw LedgerError.syntheticIdentityExhausted(fact.timestamp)
            }
            let id = EntryID.synthetic(for: fact.timestamp)
            var timestamp = fact.timestamp
            if let horizon = snapshot.horizon, timestamp < horizon {
                switch fact.kind {
                case .consentRevoked:
                    timestamp = marker.timestamp
                    retimestamped = retimestamped.addingSaturating(1)
                case .consentGranted:
                    grantsDropped = grantsDropped.addingSaturating(1)
                    continue
                default:
                    otherDropped = otherDropped.addingSaturating(1)
                    continue
                }
            }
            imported.append(LedgerEntry(id: id, account: account, timestamp: timestamp, kind: fact.kind))
        }
        imported.append(marker)
        try merge(entries: imported)
        return AbsorbReport(
            imported: imported.count,
            revocationsRetimestamped: retimestamped,
            grantsDropped: grantsDropped,
            otherDropped: otherDropped
        )
    }

    // MARK: Fold

    /// Folds snapshot + tail into the current state. Pure; the same tail
    /// always yields the same state.
    public func fold() -> ConsentState {
        var state = snapshot.state
        for entry in tail.values.sorted(by: LedgerEntry.foldOrder) {
            state.apply(entry.kind, at: entry.timestamp)
        }
        return state
    }

    // MARK: Compaction

    /// Folds the contiguous-per-node prefix of the tail into the snapshot.
    /// Only entries whose node has *no gaps* up to that entry are eligible:
    /// an entry with a missing predecessor might be re-ordered by a late
    /// arrival, and history that has been compacted cannot be re-ordered.
    public mutating func compact() {
        guard !tail.isEmpty else { return }
        // Contiguous high-water mark per node.
        var perNode: [Identifier: [UInt64]] = [:]
        for id in tail.keys where !id.isSynthetic { perNode[id.node, default: []].append(id.sequence) }
        var newWatermarks = snapshot.watermarks
        for (node, sequences) in perNode {
            var mark = snapshot.watermarks[node] ?? 0
            for sequence in sequences.sorted() {
                // Sequence numbers start at 1; `mark` is "last seen".
                if sequence == mark.addingSaturating(1) { mark = sequence } else { break }
            }
            newWatermarks[node] = mark
        }
        let eligible = tail.values.filter { entry in
            if entry.id.isSynthetic { return true }
            guard let mark = newWatermarks[entry.id.node] else { return false }
            return entry.id.sequence <= mark
        }.sorted(by: LedgerEntry.foldOrder)
        guard !eligible.isEmpty else { return }

        // Folding order must be globally consistent: an eligible entry that
        // sorts *after* an ineligible one cannot be folded yet, or the
        // ineligible one would later be applied out of order.
        let ineligibleEarliest = tail.values
            .filter { entry in
                if entry.id.isSynthetic { return false }
                guard let mark = newWatermarks[entry.id.node] else { return true }
                return entry.id.sequence > mark
            }
            .min(by: LedgerEntry.foldOrder)
        let foldable: [LedgerEntry]
        if let ineligibleEarliest {
            foldable = eligible.filter { LedgerEntry.foldOrder($0, ineligibleEarliest) }
        } else {
            foldable = eligible
        }
        guard !foldable.isEmpty else { return }

        var state = snapshot.state
        var horizon = snapshot.horizon
        var foldedMarks = snapshot.watermarks
        var foldedSynthetic = snapshot.foldedSynthetic
        for entry in foldable {
            state.apply(entry.kind, at: entry.timestamp)
            horizon = horizon.map { max($0, entry.timestamp) } ?? entry.timestamp
            if entry.id.isSynthetic {
                foldedSynthetic.insert(entry.id)
            } else {
                let current = foldedMarks[entry.id.node] ?? 0
                foldedMarks[entry.id.node] = max(current, entry.id.sequence)
            }
            tail[entry.id] = nil
        }
        snapshot = LedgerSnapshot(state: state, watermarks: foldedMarks, horizon: horizon, foldedSynthetic: foldedSynthetic)
    }

    /// Whether the owner should schedule a compaction. The value type never
    /// compacts on its own: compaction is only convergence-safe once peers
    /// have received the entries being folded (a compacted entry is no longer
    /// shipped by `merge(_:)`), and only the owning store knows that.
    public var needsCompaction: Bool { tail.count > limits.compactionThreshold }

    private mutating func enforceCapacity() throws {
        if tail.count > limits.hardCapacity {
            throw LedgerError.capacityExceeded(tail: tail.count, hardCapacity: limits.hardCapacity)
        }
    }
}
