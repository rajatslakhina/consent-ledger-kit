import Foundation

// MARK: - Age bracket

/// An age *bracket*, never a birthdate. Apple's `DeclaredAgeRange` hands the
/// app a range on purpose, and this module keeps that discipline everywhere:
/// no API in `ConsentLedger` accepts or stores a date of birth.
public struct AgeBracket: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The oldest age this module reasons about. Anything above is clamped.
    public static let maximumAge = 150

    public let lowerBound: Int
    /// `nil` means "and up" (e.g. 18+).
    public let upperBound: Int?

    /// Fails instead of trapping on nonsense input (negative ages, inverted
    /// bounds, bounds above `maximumAge`).
    public init?(lowerBound: Int, upperBound: Int?) {
        guard lowerBound >= 0, lowerBound <= AgeBracket.maximumAge else { return nil }
        if let upperBound {
            guard upperBound >= lowerBound, upperBound <= AgeBracket.maximumAge else { return nil }
        }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    // The four brackets the platform's declared-range API can produce, plus the
    // finer bands a server-side account record may hold.
    // Force-unwrap-free: these literals are validated by the failable init at
    // first use, and a `nil` here would be a programming error caught by
    // `PrimitiveTests.testCanonicalBracketsExist`.
    public static let under13 = AgeBracket(lowerBound: 0, upperBound: 12) ?? AgeBracket.unknownFallback
    public static let thirteenToFifteen = AgeBracket(lowerBound: 13, upperBound: 15) ?? AgeBracket.unknownFallback
    public static let sixteenToSeventeen = AgeBracket(lowerBound: 16, upperBound: 17) ?? AgeBracket.unknownFallback
    public static let adult = AgeBracket(lowerBound: 18, upperBound: nil) ?? AgeBracket.unknownFallback

    /// The widest possible bracket: "we know nothing". Used only as the
    /// never-taken fallback for the canonical constants above.
    static let unknownFallback = AgeBracket(uncheckedLower: 0, upper: nil)

    private init(uncheckedLower: Int, upper: Int?) {
        self.lowerBound = uncheckedLower
        self.upperBound = upper
    }

    /// Intersection of two brackets, or `nil` when they are disjoint — which is
    /// exactly the "two sources disagree" case the reconciler has to surface.
    public func intersection(_ other: AgeBracket) -> AgeBracket? {
        let lower = max(lowerBound, other.lowerBound)
        let upper: Int?
        switch (upperBound, other.upperBound) {
        case (nil, nil): upper = nil
        case let (a?, nil): upper = a
        case let (nil, b?): upper = b
        case let (a?, b?): upper = min(a, b)
        }
        if let upper, upper < lower { return nil }
        return AgeBracket(lowerBound: lower, upperBound: upper)
    }

    /// Whether *every* age in this bracket satisfies `age >= minimum`.
    public func certainlyAtLeast(_ minimum: Int) -> Bool { lowerBound >= minimum }

    /// Whether *no* age in this bracket satisfies `age >= minimum`.
    public func certainlyBelow(_ minimum: Int) -> Bool {
        guard let upperBound else { return false }
        return upperBound < minimum
    }

    public var description: String {
        if let upperBound { return "\(lowerBound)–\(upperBound)" }
        return "\(lowerBound)+"
    }
}

// MARK: - Signal sources

/// Where an age bracket came from. The order of the cases *is* the trust
/// order: a guardian attestation outranks the account record, which outranks
/// a self-declared range. `trustRank` is derived from the case so the two can
/// never drift apart.
public enum AgeSignalSource: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// The on-device declared range (Apple's `DeclaredAgeRange`, or the
    /// app's own age screen). Self-declared; lowest trust.
    case declaredRange
    /// The server-side account record (registration age band, payment KYC…).
    case serverAccountAge
    /// A guardian completed a consent flow that attested the child's bracket.
    case guardianAttestation

    public var trustRank: Int {
        switch self {
        case .declaredRange: return 1
        case .serverAccountAge: return 2
        case .guardianAttestation: return 3
        }
    }

    public static func < (lhs: AgeSignalSource, rhs: AgeSignalSource) -> Bool {
        lhs.trustRank < rhs.trustRank
    }
}

/// One observation of an age bracket from one source.
public struct AgeSignal: Hashable, Sendable, Codable {
    public let source: AgeSignalSource
    public let bracket: AgeBracket
    /// When the *source* observed it — an HLC timestamp so a signal that
    /// arrives late (out of order) never overrides a newer one from the same
    /// source.
    public let observedAt: HybridTimestamp

    public init(source: AgeSignalSource, bracket: AgeBracket, observedAt: HybridTimestamp) {
        self.source = source
        self.bracket = bracket
        self.observedAt = observedAt
    }
}

// MARK: - Providers

/// The seam between this module and the platform. One conformance per
/// source; the orchestrator polls all of them and feeds the reconciler.
///
/// A conformance returns `nil` when it has *no* signal (the user never
/// declared, the account has no age band, no guardian has attested). It
/// throws only for transport failures. The distinction matters: `nil` is a
/// stable fact the gate must fail closed on; a throw is retried.
public protocol AgeSignalProvider: Sendable {
    var source: AgeSignalSource { get }
    func currentSignal() async throws -> AgeSignal?
}

/// A provider backed by a closure. This is how the system `DeclaredAgeRange`
/// request is adapted on iOS 26+: the closure calls
/// `AgeRangeService.shared.requestAgeRange(...)`, maps the returned range to
/// an `AgeBracket`, and stamps it with the orchestrator's clock. On platforms
/// without the framework (or in tests) the same type is a mock.
public struct ClosureAgeSignalProvider: AgeSignalProvider {
    public let source: AgeSignalSource
    private let fetch: @Sendable () async throws -> AgeSignal?

    public init(source: AgeSignalSource, fetch: @escaping @Sendable () async throws -> AgeSignal?) {
        self.source = source
        self.fetch = fetch
    }

    public func currentSignal() async throws -> AgeSignal? {
        try await fetch()
    }
}

// MARK: - Reconciliation

/// How long a signal from each source stays load-bearing. A stale signal is
/// not *wrong*, it is just no longer allowed to open a gate on its own.
public struct ReconciliationPolicy: Sendable, Equatable {
    public var maximumAgeMilliseconds: [AgeSignalSource: Int64]

    public init(maximumAgeMilliseconds: [AgeSignalSource: Int64]) {
        self.maximumAgeMilliseconds = maximumAgeMilliseconds
    }

    /// Declared ranges are re-asked every 30 days, account ages every 7 days,
    /// guardian attestations every 365 days.
    public static let standard = ReconciliationPolicy(maximumAgeMilliseconds: [
        .declaredRange: Int64(30) * 24 * 60 * 60 * 1000,
        .serverAccountAge: Int64(7) * 24 * 60 * 60 * 1000,
        .guardianAttestation: Int64(365) * 24 * 60 * 60 * 1000
    ])

    public func isFresh(_ signal: AgeSignal, nowMilliseconds now: Int64) -> Bool {
        guard let maximum = maximumAgeMilliseconds[signal.source] else { return false }
        let age = now.subtractingSaturating(signal.observedAt.wallMilliseconds)
        return age >= 0 && age <= maximum
    }
}

/// Two fresh sources whose brackets do not overlap.
public struct AgeDisagreement: Hashable, Sendable {
    public let higherTrust: AgeSignal
    public let lowerTrust: AgeSignal
}

/// The reconciler's output. Two brackets, on purpose:
///
/// - `attested` is the bracket of the highest-trust fresh source. It is what
///   the UI shows and what a guardian's attestation asserts.
/// - `conservative` is the intersection of every fresh source, or — when the
///   sources disagree — the *youngest* fresh bracket. The gate uses this one.
///
/// The rule a staff engineer has to defend: **disagreement never makes the
/// child older.** If the server says 13–15 and the device says under 13, the
/// gate treats the user as under 13 until a guardian attestation (the only
/// source that outranks both) resolves it.
public struct ReconciledAge: Hashable, Sendable {
    public let attested: AgeSignal?
    public let conservative: AgeBracket?
    public let disagreements: [AgeDisagreement]
    public let staleSources: [AgeSignalSource]

    public var isKnown: Bool { conservative != nil }
}

/// Pure, order-independent reconciliation of the latest signal per source.
public enum AgeSignalReconciler {
    /// Keeps, per source, the signal with the greatest HLC timestamp. Because
    /// HLC order is total, feeding the same signals in any order yields the
    /// same result — the property `ReconciliationTests` checks by permutation.
    public static func latestPerSource(_ signals: [AgeSignal]) -> [AgeSignalSource: AgeSignal] {
        var latest: [AgeSignalSource: AgeSignal] = [:]
        for signal in signals {
            if let existing = latest[signal.source], existing.observedAt >= signal.observedAt {
                continue
            }
            latest[signal.source] = signal
        }
        return latest
    }

    public static func reconcile(
        _ signals: [AgeSignal],
        policy: ReconciliationPolicy,
        nowMilliseconds now: Int64
    ) -> ReconciledAge {
        let latest = latestPerSource(signals)
        var fresh: [AgeSignal] = []
        var stale: [AgeSignalSource] = []
        for source in AgeSignalSource.allCases {
            guard let signal = latest[source] else { continue }
            if policy.isFresh(signal, nowMilliseconds: now) {
                fresh.append(signal)
            } else {
                stale.append(source)
            }
        }
        // Highest trust first; ties impossible because there is one per source.
        fresh.sort { $0.source > $1.source }

        guard let top = fresh.first else {
            return ReconciledAge(attested: nil, conservative: nil, disagreements: [], staleSources: stale)
        }

        // A guardian attestation is the only source allowed to *raise* the
        // conservative bracket: it is the resolution mechanism for a dispute,
        // not a party to it.
        if top.source == .guardianAttestation {
            let disagreements = fresh.dropFirst().compactMap { lower -> AgeDisagreement? in
                top.bracket.intersection(lower.bracket) == nil
                    ? AgeDisagreement(higherTrust: top, lowerTrust: lower)
                    : nil
            }
            return ReconciledAge(attested: top, conservative: top.bracket, disagreements: disagreements, staleSources: stale)
        }

        var intersection: AgeBracket? = top.bracket
        var disagreements: [AgeDisagreement] = []
        var youngest = top.bracket
        for lower in fresh.dropFirst() {
            if lower.bracket.lowerBound < youngest.lowerBound { youngest = lower.bracket }
            if let current = intersection, let next = current.intersection(lower.bracket) {
                intersection = next
            } else {
                intersection = nil
                disagreements.append(AgeDisagreement(higherTrust: top, lowerTrust: lower))
            }
        }
        return ReconciledAge(
            attested: top,
            conservative: intersection ?? youngest,
            disagreements: disagreements,
            staleSources: stale
        )
    }
}
