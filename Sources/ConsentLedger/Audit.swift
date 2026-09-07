import Foundation

// MARK: - Convergence audit

/// Checks that a fold strategy is order-independent by folding every
/// permutation of a small entry set (n ≤ 7, 5 040 folds) and comparing the
/// results. Ships in the library, not just the tests, so a team can run it
/// in CI against its own reducer changes.
///
/// The shipped strategy is `Ledger`'s sort-then-apply. The negative control,
/// `arrivalOrderFold`, applies entries in the order given — the bug every
/// "just apply events as they arrive" sync layer has — and the audit must
/// *fail* on it (see `AuditTests.testConvergenceAuditRejectsArrivalOrderFold`).
public enum ConvergenceAudit {
    public typealias FoldStrategy = @Sendable ([LedgerEntry]) -> ConsentState

    public struct Report: Sendable, Equatable {
        public let permutationsChecked: Int
        public let distinctOutcomes: Int
        public var converged: Bool { distinctOutcomes <= 1 }
    }

    public static let maximumEntries = 7

    /// The strategy `Ledger.fold` uses, expressed over a plain entry list.
    public static let shippedFold: FoldStrategy = { entries in
        var state = ConsentState()
        for entry in entries.sorted(by: LedgerEntry.foldOrder) {
            state.apply(entry.kind, at: entry.timestamp)
        }
        return state
    }

    /// Negative control: apply in arrival order.
    public static let arrivalOrderFold: FoldStrategy = { entries in
        var state = ConsentState()
        for entry in entries { state.apply(entry.kind, at: entry.timestamp) }
        return state
    }

    /// Returns `nil` if `entries` is empty or larger than `maximumEntries`.
    public static func check(_ entries: [LedgerEntry], strategy: FoldStrategy) -> Report? {
        guard !entries.isEmpty, entries.count <= maximumEntries else { return nil }
        var outcomes = Set<ConsentState>()
        var count = 0
        forEachPermutation(of: entries) { permutation in
            outcomes.insert(strategy(permutation))
            count = count.addingSaturating(1)
        }
        return Report(permutationsChecked: count, distinctOutcomes: outcomes.count)
    }

    /// Heap's algorithm; iterative, bounds-checked, no recursion depth risk.
    static func forEachPermutation<T>(of items: [T], _ body: ([T]) -> Void) {
        var array = items
        let n = array.count
        guard n > 0 else { return }
        var counters = [Int](repeating: 0, count: n)
        body(array)
        var i = 0
        while i < n {
            guard i < counters.count else { return }
            if counters[i] < i {
                let j = i % 2 == 0 ? 0 : counters[i]
                guard j < n else { return }
                array.swapAt(j, i)
                body(array)
                counters[i] += 1
                i = 0
            } else {
                counters[i] = 0
                i += 1
            }
        }
    }
}

// MARK: - Fail-closed audit

/// Proves the gate is fail-closed for every capability in every region —
/// including `nil` and a region the policy has never heard of — when the
/// age is unknown, ambiguous, or below the minimum, and when consent is
/// required but absent. Parameterised over the evaluator so a broken one can
/// be shown to fail the audit.
public enum FailClosedAudit {
    public typealias Evaluator = @Sendable (Capability, ReconciledAge, ConsentState, Identifier?, JurisdictionPolicy) -> GateDecision

    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public let capability: Identifier
        public let region: Identifier?
        public let scenario: String

        public var description: String {
            "\(capability) in \(region?.rawValue ?? "nil"): allowed under '\(scenario)'"
        }
    }

    public static let shippedEvaluator: Evaluator = { capability, age, consent, region, policy in
        CapabilityGate.evaluate(capability, age: age, consent: consent, region: region, policy: policy)
    }

    /// Negative control: "unknown age is an adult" — the default every
    /// `if let age, age < 13` gate silently has.
    public static let optimisticEvaluator: Evaluator = { capability, age, consent, region, policy in
        if age.conservative == nil { return .allowed(consentBy: nil) }
        return CapabilityGate.evaluate(capability, age: age, consent: consent, region: region, policy: policy)
    }

    public static func check(
        policy: JurisdictionPolicy,
        capabilities: [Capability],
        evaluator: Evaluator
    ) -> [Violation] {
        var regions: [Identifier?] = [nil]
        regions.append(contentsOf: policy.rules.keys.sorted().map { Optional($0) })
        // A region code no policy has an entry for.
        regions.append("ZZ-unlisted")

        let unknownAge = ReconciledAge(attested: nil, conservative: nil, disagreements: [], staleSources: [])
        let noConsent = ConsentState()

        var violations: [Violation] = []
        for capability in capabilities {
            for region in regions {
                if evaluator(capability, unknownAge, noConsent, region, policy).isAllowed {
                    violations.append(Violation(capability: capability.id, region: region, scenario: "unknown age"))
                }
                let rule = policy.rule(for: capability.id, in: region)
                if rule.minimumAge > 0,
                   let below = AgeBracket(lowerBound: 0, upperBound: rule.minimumAge - 1) {
                    let age = ReconciledAge(attested: nil, conservative: below, disagreements: [], staleSources: [])
                    if evaluator(capability, age, noConsent, region, policy).isAllowed {
                        violations.append(Violation(capability: capability.id, region: region, scenario: "below minimum age"))
                    }
                }
                if let threshold = rule.guardianConsentBelow, threshold > rule.minimumAge,
                   let minor = AgeBracket(lowerBound: rule.minimumAge, upperBound: threshold - 1) {
                    let age = ReconciledAge(attested: nil, conservative: minor, disagreements: [], staleSources: [])
                    if evaluator(capability, age, noConsent, region, policy).isAllowed {
                        violations.append(Violation(capability: capability.id, region: region, scenario: "consent required, none given"))
                    }
                }
            }
        }
        return violations
    }
}
