import Foundation

// MARK: - Events

/// What a guardian consented *to*. Consent is scoped, never a global boolean:
/// a guardian can allow chat and refuse generative features.
public enum ConsentScope: Hashable, Sendable, Codable {
    case all
    case capabilities(Set<Identifier>)

    public func covers(_ capability: Identifier) -> Bool {
        switch self {
        case .all: return true
        case .capabilities(let set): return set.contains(capability)
        }
    }
}

/// The vocabulary of the ledger. Every case is a *fact that happened*, never
/// a command — which is what makes the log replayable and mergeable.
public enum ConsentEventKind: Hashable, Sendable, Codable {
    /// The user (or the device owner) declared an age bracket.
    case ageDeclared(AgeBracket)
    /// A higher-trust source (server record / guardian attestation) verified a bracket.
    case ageVerified(AgeBracket, source: AgeSignalSource)
    /// The app asked a guardian for consent.
    case consentRequested(guardian: Identifier, scope: ConsentScope)
    /// The guardian granted consent for a scope.
    case consentGranted(guardian: Identifier, scope: ConsentScope)
    /// The guardian revoked consent for a scope.
    case consentRevoked(guardian: Identifier, scope: ConsentScope)
    /// Another account's ledger was merged into this one (child signed in on a
    /// device that had a guest account, or two accounts were linked).
    case accountMerged(from: Identifier)

    /// Ordering inside one HLC instant. Revocation sorts *after* a grant with
    /// the same `(wall, logical)` so that when two devices act in the same
    /// millisecond, the fold applies the revocation last and it wins. This is
    /// the "ties fail closed" rule, enforced by ordering rather than by a
    /// special case in the reducer.
    var tieBreakRank: Int {
        switch self {
        case .accountMerged: return 0
        case .ageDeclared: return 1
        case .ageVerified: return 2
        case .consentRequested: return 3
        case .consentGranted: return 4
        case .consentRevoked: return 5
        }
    }
}

// MARK: - State

public enum ConsentPhase: String, Hashable, Sendable, Codable, Comparable {
    case unknown
    case declared
    case verified
    case consentPending
    case consentGranted
    case consentRevoked

    /// The single source of truth for "how far along is this account".
    var rank: Int {
        switch self {
        case .unknown: return 0
        case .declared: return 1
        case .verified: return 2
        case .consentPending: return 3
        case .consentGranted: return 4
        case .consentRevoked: return 5
        }
    }

    public static func < (lhs: ConsentPhase, rhs: ConsentPhase) -> Bool { lhs.rank < rhs.rank }
}

/// A grant or revocation for a scope, with the timestamp that decided it.
public struct ConsentGrant: Hashable, Sendable, Codable {
    public let guardian: Identifier
    public let scope: ConsentScope
    public let decidedAt: HybridTimestamp
    public let isGranted: Bool
}

/// One guardian's standing decisions. A decision about `.all` supersedes
/// everything that guardian said before; a decision about specific
/// capabilities overrides the blanket decision for those capabilities only.
/// "Grant all, then revoke chat" therefore leaves purchases granted and chat
/// revoked — the semantics a parent expects.
public struct GuardianDecisions: Hashable, Sendable, Codable {
    public private(set) var blanket: ConsentGrant?
    public private(set) var perCapability: [Identifier: ConsentGrant]

    public init() {
        blanket = nil
        perCapability = [:]
    }

    mutating func record(_ decision: ConsentGrant) {
        switch decision.scope {
        case .all:
            blanket = decision
            perCapability = [:]
        case .capabilities(let set):
            for capability in set { perCapability[capability] = decision }
        }
    }

    /// The decision that applies to `capability`, if any.
    public func decision(for capability: Identifier) -> ConsentGrant? {
        perCapability[capability] ?? blanket
    }

    public var containsRevocation: Bool {
        (blanket.map { !$0.isGranted } ?? false) || perCapability.values.contains { !$0.isGranted }
    }

    /// Every distinct decision, for replay (see `Ledger.absorb`).
    public var allDecisions: [ConsentGrant] {
        var seen = Set<ConsentGrant>()
        var result: [ConsentGrant] = []
        for decision in [blanket].compactMap({ $0 }) + perCapability.values.sorted(by: { $0.decidedAt < $1.decidedAt }) {
            if seen.insert(decision).inserted { result.append(decision) }
        }
        return result
    }
}

/// The folded state of one account's ledger.
public struct ConsentState: Hashable, Sendable, Codable {
    public private(set) var phase: ConsentPhase
    public private(set) var declaredBracket: AgeBracket?
    public private(set) var declaredAt: HybridTimestamp?
    public private(set) var verifiedBracket: AgeBracket?
    public private(set) var verifiedBy: AgeSignalSource?
    public private(set) var verifiedAt: HybridTimestamp?
    /// Standing decisions per guardian. Per-capability answers are derived by
    /// `consentStatus(for:)`, which is where "revoke beats grant" lives.
    public private(set) var decisions: [Identifier: GuardianDecisions]
    public private(set) var pendingRequests: [Identifier: ConsentScope]
    public private(set) var mergedAccounts: [Identifier]
    /// Events the reducer refused (e.g. a grant that arrived before any age
    /// was declared). Kept, not dropped: an audit needs to see them, and a
    /// replica that folds the same log must reach the same rejections.
    public private(set) var rejectedEvents: Int

    public init() {
        phase = .unknown
        declaredBracket = nil
        declaredAt = nil
        verifiedBracket = nil
        verifiedBy = nil
        verifiedAt = nil
        decisions = [:]
        pendingRequests = [:]
        mergedAccounts = []
        rejectedEvents = 0
    }

    public enum CapabilityConsent: Hashable, Sendable {
        case granted(by: Identifier)
        case revoked(by: Identifier)
        case pending(guardian: Identifier)
        case none
    }

    /// Fail-closed resolution across guardians: any guardian's revocation of
    /// a scope that covers the capability beats any other guardian's grant.
    /// Two guardians are a shared-custody edge case a consumer app must get
    /// right in the child's favour, not the feature's.
    public func consentStatus(for capability: Identifier) -> CapabilityConsent {
        var grant: Identifier?
        for (guardian, standing) in decisions.sorted(by: { $0.key < $1.key }) {
            guard let decision = standing.decision(for: capability) else { continue }
            if !decision.isGranted { return .revoked(by: guardian) }
            if grant == nil { grant = guardian }
        }
        if let grant { return .granted(by: grant) }
        for (guardian, scope) in pendingRequests.sorted(by: { $0.key < $1.key }) where scope.covers(capability) {
            return .pending(guardian: guardian)
        }
        return .none
    }

    // MARK: Reducer

    /// The state machine. Pure and total: every input yields a new state; an
    /// invalid transition increments `rejectedEvents` instead of throwing, so
    /// folding never aborts halfway through a log.
    ///
    /// unknown → declared → verified → consentPending → consentGranted ⇄ consentRevoked
    ///
    /// Rejected: a request or grant before any age is known (a grant with no
    /// age is the shape of a replay attack or a sync bug, and it would *open*
    /// a gate). Never rejected: a revocation (it only ever closes gates).
    public mutating func apply(_ kind: ConsentEventKind, at timestamp: HybridTimestamp) {
        switch kind {
        case .ageDeclared(let bracket):
            declaredBracket = bracket
            declaredAt = timestamp
            if phase < .declared { phase = .declared }

        case let .ageVerified(bracket, source):
            // Verification never downgrades: a server record cannot overwrite
            // a guardian attestation. Equal or higher trust replaces.
            if let verifiedBy, verifiedBy > source { return }
            verifiedBracket = bracket
            verifiedBy = source
            verifiedAt = timestamp
            if phase < .verified { phase = .verified }

        case let .consentRequested(guardian, scope):
            guard phase >= .declared else { rejectedEvents = rejectedEvents.addingSaturating(1); return }
            pendingRequests[guardian] = scope
            if phase < .consentPending { phase = .consentPending }

        case let .consentGranted(guardian, scope):
            guard phase >= .declared else { rejectedEvents = rejectedEvents.addingSaturating(1); return }
            pendingRequests[guardian] = nil
            decisions[guardian, default: GuardianDecisions()]
                .record(ConsentGrant(guardian: guardian, scope: scope, decidedAt: timestamp, isGranted: true))
            phase = decisions.values.contains { $0.containsRevocation } ? .consentRevoked : .consentGranted

        case let .consentRevoked(guardian, scope):
            // A revocation is never rejected, whatever the phase: recording
            // "no" before we know the age closes gates, which is always safe.
            pendingRequests[guardian] = nil
            decisions[guardian, default: GuardianDecisions()]
                .record(ConsentGrant(guardian: guardian, scope: scope, decidedAt: timestamp, isGranted: false))
            phase = .consentRevoked

        case .accountMerged(let other):
            if !mergedAccounts.contains(other) { mergedAccounts.append(other) }
        }
    }
}
