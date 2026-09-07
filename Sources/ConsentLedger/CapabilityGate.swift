import Foundation

// MARK: - Capabilities

/// A feature the app gates on age and consent. Features depend on
/// `CapabilityGate`, never on a raw age check — that is the module boundary
/// this whole package exists to enforce.
public struct Capability: Hashable, Sendable, Codable, Identifiable {
    public let id: Identifier
    public let displayName: String

    public init(id: Identifier, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    // The capabilities a large consumer app typically gates. IDs are string
    // literals validated by `Identifier`'s literal initialiser;
    // `PrimitiveTests.testCanonicalCapabilitiesExist` asserts none collapsed.
    public static let chat = Capability(id: "chat", displayName: "Chat & DMs")
    public static let userGeneratedContent = Capability(id: "ugc", displayName: "Post reviews & photos")
    public static let generativeFeatures = Capability(id: "generative", displayName: "AI assistant")
    public static let targetedOffers = Capability(id: "targeted-offers", displayName: "Personalised offers")
    public static let purchases = Capability(id: "purchases", displayName: "Checkout")

    public static let standardSet: [Capability] = [
        .chat, .userGeneratedContent, .generativeFeatures, .targetedOffers, .purchases
    ]
}

// MARK: - Jurisdiction policy

/// What one jurisdiction requires for one capability.
public struct CapabilityRule: Hashable, Sendable, Codable {
    /// The user must certainly be at least this old.
    public var minimumAge: Int
    /// Below this age (and at or above `minimumAge`), verifiable guardian
    /// consent is required. `nil` = consent never required.
    public var guardianConsentBelow: Int?

    public init(minimumAge: Int, guardianConsentBelow: Int?) {
        self.minimumAge = max(0, min(minimumAge, AgeBracket.maximumAge))
        self.guardianConsentBelow = guardianConsentBelow.map { max(0, min($0, AgeBracket.maximumAge)) }
    }

    /// Most-restrictive combination. Rules form a semilattice under this, so
    /// combining in any order gives the same answer — which is what lets the
    /// "unknown region" rule be *derived* from the known ones.
    public func meet(_ other: CapabilityRule) -> CapabilityRule {
        let consent: Int?
        switch (guardianConsentBelow, other.guardianConsentBelow) {
        case (nil, nil): consent = nil
        case let (a?, nil): consent = a
        case let (nil, b?): consent = b
        case let (a?, b?): consent = max(a, b)
        }
        return CapabilityRule(minimumAge: max(minimumAge, other.minimumAge), guardianConsentBelow: consent)
    }
}

/// Region → capability → rule. Compiled into the binary and versioned; a
/// remote update can only *add* restrictions (see `applying(update:)`).
public struct JurisdictionPolicy: Hashable, Sendable, Codable {
    public let version: Int
    public let rules: [Identifier: [Identifier: CapabilityRule]]
    /// The rule for a capability nobody wrote a rule for, in a region we do
    /// recognise. This is the app's own terms-of-service floor.
    public let baseline: CapabilityRule

    public init(version: Int, rules: [Identifier: [Identifier: CapabilityRule]], baseline: CapabilityRule) {
        self.version = version
        self.rules = rules
        self.baseline = baseline
    }

    /// The rule that applies to `capability` in `region`.
    ///
    /// - A known region with a rule → that rule.
    /// - A known region without a rule for this capability → `baseline`.
    /// - An unknown region (`nil`, or a code we have no entry for) → the
    ///   *meet* of every known region's rule for this capability: the
    ///   strictest thing any law we know of asks. "We don't know where the
    ///   user is" must never be the loosest branch.
    public func rule(for capability: Identifier, in region: Identifier?) -> CapabilityRule {
        if let region, let regionRules = rules[region] {
            return regionRules[capability] ?? baseline
        }
        var combined = baseline
        for regionRules in rules.values {
            if let rule = regionRules[capability] { combined = combined.meet(rule) }
        }
        return combined
    }

    /// Remote policy updates are monotone: each rule in the update is met
    /// with the compiled-in one, so a mis-published config can tighten a
    /// gate but never loosen it below what shipped in the binary.
    ///
    /// Regions the binary does not know are *ignored*, not added. An unknown
    /// region already gets the strictest known rule, so "recognising" a new
    /// region remotely could only ever loosen it — which is exactly the
    /// change that must ship through App Review, not through a config push.
    public func applying(update: JurisdictionPolicy) -> JurisdictionPolicy {
        guard update.version > version else { return self }
        var merged = rules
        for (region, regionRules) in update.rules {
            guard var target = merged[region] else { continue }
            for (capability, rule) in regionRules {
                target[capability] = (target[capability] ?? baseline).meet(rule)
            }
            merged[region] = target
        }
        return JurisdictionPolicy(version: update.version, rules: merged, baseline: baseline.meet(update.baseline))
    }
}

// MARK: - Decisions

public enum GateDenialReason: String, Hashable, Sendable, Codable {
    /// No fresh age signal from any source.
    case ageUnknown
    /// The conservative bracket is certainly below the minimum age.
    case belowMinimumAge
    /// The bracket straddles the minimum: some ages allowed, some not.
    case ageAmbiguous
    /// Consent is required and no guardian has granted it.
    case consentRequired
    /// A guardian granted and later revoked, or one guardian revoked.
    case consentRevoked
    /// Consent was requested and is awaiting the guardian.
    case consentPending
}

public enum GateDecision: Hashable, Sendable, Codable {
    case allowed(consentBy: Identifier?)
    case denied(GateDenialReason)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Pure evaluation. No I/O, no clock, no defaults that open a gate.
public enum CapabilityGate {
    public static func evaluate(
        _ capability: Capability,
        age: ReconciledAge,
        consent: ConsentState,
        region: Identifier?,
        policy: JurisdictionPolicy
    ) -> GateDecision {
        let rule = policy.rule(for: capability.id, in: region)

        guard let bracket = age.conservative else { return .denied(.ageUnknown) }
        if bracket.certainlyBelow(rule.minimumAge) { return .denied(.belowMinimumAge) }
        guard bracket.certainlyAtLeast(rule.minimumAge) else { return .denied(.ageAmbiguous) }

        // Consent is required unless the user is *certainly* at or above the
        // consent threshold. "Might be 12, might be 13" needs consent.
        if let threshold = rule.guardianConsentBelow, !bracket.certainlyAtLeast(threshold) {
            switch consent.consentStatus(for: capability.id) {
            case .granted(let guardian): return .allowed(consentBy: guardian)
            case .revoked: return .denied(.consentRevoked)
            case .pending: return .denied(.consentPending)
            case .none: return .denied(.consentRequired)
            }
        }
        return .allowed(consentBy: nil)
    }

    public static func snapshot(
        capabilities: [Capability],
        age: ReconciledAge,
        consent: ConsentState,
        region: Identifier?,
        policy: JurisdictionPolicy,
        version: UInt64,
        producedAt: HybridTimestamp
    ) -> GateSnapshot {
        var decisions: [Identifier: GateDecision] = [:]
        for capability in capabilities {
            decisions[capability.id] = evaluate(capability, age: age, consent: consent, region: region, policy: policy)
        }
        return GateSnapshot(version: version, producedAt: producedAt, policyVersion: policy.version, region: region, decisions: decisions)
    }
}

/// The unit that is propagated server-side so remote config / feature flags
/// switch the same capabilities off on the backend. Versioned and monotone.
public struct GateSnapshot: Hashable, Sendable, Codable {
    public let version: UInt64
    public let producedAt: HybridTimestamp
    public let policyVersion: Int
    public let region: Identifier?
    public let decisions: [Identifier: GateDecision]

    public init(version: UInt64, producedAt: HybridTimestamp, policyVersion: Int, region: Identifier?, decisions: [Identifier: GateDecision]) {
        self.version = version
        self.producedAt = producedAt
        self.policyVersion = policyVersion
        self.region = region
        self.decisions = decisions
    }

    /// Fail closed for anything the snapshot has no entry for.
    public func decision(for capability: Identifier) -> GateDecision {
        decisions[capability] ?? .denied(.ageUnknown)
    }
}
