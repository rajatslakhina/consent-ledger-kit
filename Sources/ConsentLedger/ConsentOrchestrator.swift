import Foundation

// MARK: - Configuration

public struct OrchestratorConfiguration: Sendable {
    public var node: Identifier
    public var account: Identifier
    public var capabilities: [Capability]
    public var policy: JurisdictionPolicy
    public var region: Identifier?
    public var reconciliation: ReconciliationPolicy
    public var ledgerLimits: Ledger.Limits
    public var retry: RetryPolicy

    public init(
        node: Identifier,
        account: Identifier,
        capabilities: [Capability] = Capability.standardSet,
        policy: JurisdictionPolicy,
        region: Identifier?,
        reconciliation: ReconciliationPolicy = .standard,
        ledgerLimits: Ledger.Limits = .standard,
        retry: RetryPolicy = .standard
    ) {
        self.node = node
        self.account = account
        self.capabilities = capabilities
        self.policy = policy
        self.region = region
        self.reconciliation = reconciliation
        self.ledgerLimits = ledgerLimits
        self.retry = retry
    }
}

/// What the orchestrator exposes to the UI and to features. A value, so a
/// view can hold it without holding the actor.
public struct OrchestratorStatus: Sendable, Hashable {
    public let age: ReconciledAge
    public let consent: ConsentState
    public let snapshot: GateSnapshot
    public let ledgerTailCount: Int
    public let lastAcknowledged: HybridTimestamp?
    public let lastPropagationError: String?
}

// MARK: - Orchestrator

/// One instance per (device, account). Owns the clock, the ledger, the
/// signal cache and the publish pipeline, and is the only place a
/// `GateSnapshot` version is minted.
///
/// Reentrancy contract: every method that changes state does so *before*
/// its first `await`. `evaluateAndPublish` mints the version and stores the
/// snapshot synchronously, then awaits the propagator. Two overlapping calls
/// therefore mint distinct, increasing versions; whichever ack arrives last
/// cannot regress `lastAcknowledged` because acks are folded with `max`,
/// and the server's monotone contract rejects the older one.
public actor ConsentOrchestrator {
    public let configuration: OrchestratorConfiguration

    private var clock: HybridClock
    private var ledger: Ledger
    private var sequence: UInt64 = 0
    private var signals: [AgeSignalSource: AgeSignal] = [:]
    private var policy: JurisdictionPolicy
    private var region: Identifier?
    private var gateVersion: UInt64 = 0
    private var currentSnapshot: GateSnapshot?
    private var lastAcknowledged: HybridTimestamp?
    private var lastPropagationError: String?
    /// Entry IDs the sync layer has confirmed a peer holds. Compaction is
    /// only allowed for entries in this set.
    private var acknowledgedByPeers: Set<EntryID> = []

    private let providers: [AgeSignalProvider]
    private let propagator: GatePropagator
    private let sleeper: Sleeper
    private let now: @Sendable () -> Int64

    public init(
        configuration: OrchestratorConfiguration,
        providers: [AgeSignalProvider],
        propagator: GatePropagator,
        sleeper: Sleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Int64 = { WallClock.nowMilliseconds() }
    ) {
        self.configuration = configuration
        self.clock = HybridClock(node: configuration.node)
        self.ledger = Ledger(account: configuration.account, limits: configuration.ledgerLimits)
        self.policy = configuration.policy
        self.region = configuration.region
        self.providers = providers
        self.propagator = propagator
        self.sleeper = sleeper
        self.now = now
    }

    // MARK: Reads

    public var status: OrchestratorStatus {
        let age = reconciledAge()
        let consent = ledger.fold()
        let snapshot = currentSnapshot ?? CapabilityGate.snapshot(
            capabilities: configuration.capabilities,
            age: age,
            consent: consent,
            region: region,
            policy: policy,
            version: gateVersion,
            producedAt: HybridTimestamp(wallMilliseconds: clock.lastWall, logical: clock.lastLogical, node: configuration.node)
        )
        return OrchestratorStatus(
            age: age,
            consent: consent,
            snapshot: snapshot,
            ledgerTailCount: ledger.tailCount,
            lastAcknowledged: lastAcknowledged,
            lastPropagationError: lastPropagationError
        )
    }

    /// The decision every feature asks for. Reads the last evaluated
    /// snapshot; if nothing has been evaluated yet, evaluates now (without
    /// publishing). Never returns "allowed" by default.
    public func decision(for capability: Capability) -> GateDecision {
        if let currentSnapshot { return currentSnapshot.decision(for: capability.id) }
        return evaluateLocally().decision(for: capability.id)
    }

    public var ledgerSnapshot: Ledger { ledger }

    // MARK: Signals

    /// Polls every provider once. Transport errors are collected, not fatal:
    /// a source that cannot answer simply does not contribute a fresh signal
    /// and the gate fails closed on it.
    @discardableResult
    public func refreshSignals() async -> [AgeSignalSource: Error] {
        var errors: [AgeSignalSource: Error] = [:]
        for provider in providers {
            do {
                if let signal = try await provider.currentSignal() {
                    ingest(signal)
                }
            } catch {
                errors[provider.source] = error
            }
        }
        return errors
    }

    /// Records a signal observed by *this* orchestrator (e.g. the user just
    /// completed the declared-range prompt).
    public func observe(source: AgeSignalSource, bracket: AgeBracket) throws {
        let timestamp = clock.tick(nowMilliseconds: now())
        let signal = AgeSignal(source: source, bracket: bracket, observedAt: timestamp)
        try ingest(signal, appending: true)
    }

    private func ingest(_ signal: AgeSignal) {
        // Errors from appending a provider-sourced signal cannot be surfaced
        // to a caller, so they are recorded as a propagation error for the
        // status view and the signal still counts for reconciliation.
        do { try ingest(signal, appending: true) } catch { lastPropagationError = "\(error)" }
    }

    private func ingest(_ signal: AgeSignal, appending: Bool) throws {
        clock.receive(signal.observedAt, nowMilliseconds: now())
        if let existing = signals[signal.source], existing.observedAt >= signal.observedAt { return }
        signals[signal.source] = signal
        guard appending else { return }
        let kind: ConsentEventKind = signal.source == .declaredRange
            ? .ageDeclared(signal.bracket)
            : .ageVerified(signal.bracket, source: signal.source)
        try appendLocal(kind, at: signal.observedAt)
    }

    // MARK: Consent

    public func requestConsent(from guardian: Identifier, scope: ConsentScope) throws {
        try appendLocal(.consentRequested(guardian: guardian, scope: scope))
    }

    public func grantConsent(guardian: Identifier, scope: ConsentScope) throws {
        try appendLocal(.consentGranted(guardian: guardian, scope: scope))
    }

    public func revokeConsent(guardian: Identifier, scope: ConsentScope) throws {
        try appendLocal(.consentRevoked(guardian: guardian, scope: scope))
    }

    private func appendLocal(_ kind: ConsentEventKind, at timestamp: HybridTimestamp? = nil) throws {
        let stamp = timestamp ?? clock.tick(nowMilliseconds: now())
        sequence = sequence.addingSaturating(1)
        let entry = LedgerEntry(
            id: EntryID(node: configuration.node, sequence: sequence),
            account: configuration.account,
            timestamp: stamp,
            kind: kind
        )
        try ledger.append(entry)
    }

    // MARK: Sync

    /// Entries a peer needs. The sync layer ships these and, once the peer
    /// confirms receipt, calls `acknowledge(_:)`.
    public func exportEntries() -> [LedgerEntry] {
        Array(ledger.tail.values)
    }

    /// Merges entries from a peer replica of the same account. Timestamps
    /// are folded into the local clock first so anything this device does
    /// afterwards sorts after what it just learned. Age evidence carried by
    /// the entries updates the signal cache, so a second device converges
    /// on the same reconciled age without re-asking the platform.
    public func importEntries(_ entries: [LedgerEntry]) throws {
        for entry in entries { clock.receive(entry.timestamp, nowMilliseconds: now()) }
        try ledger.merge(entries: entries)
        for entry in entries {
            switch entry.kind {
            case .ageDeclared(let bracket):
                try ingest(AgeSignal(source: .declaredRange, bracket: bracket, observedAt: entry.timestamp), appending: false)
            case let .ageVerified(bracket, source):
                try ingest(AgeSignal(source: source, bracket: bracket, observedAt: entry.timestamp), appending: false)
            default:
                continue
            }
        }
    }

    public func acknowledge(_ ids: [EntryID]) {
        for id in ids where ledger.tail[id] != nil { acknowledgedByPeers.insert(id) }
    }

    /// Compacts only when every uncompacted entry is known to be held by a
    /// peer. Returns whether compaction ran.
    @discardableResult
    public func compactIfSafe() -> Bool {
        guard ledger.needsCompaction else { return false }
        guard ledger.tail.keys.allSatisfy({ acknowledgedByPeers.contains($0) }) else { return false }
        let before = ledger.tailCount
        ledger.compact()
        acknowledgedByPeers = acknowledgedByPeers.filter { ledger.tail[$0] != nil }
        return ledger.tailCount < before
    }

    /// Absorbs another account's ledger into this one (account merge). See
    /// `AbsorbReport` for what happens to facts older than this ledger's
    /// compaction horizon.
    @discardableResult
    public func absorb(_ other: Ledger) throws -> AbsorbReport {
        let stamp = clock.tick(nowMilliseconds: now())
        sequence = sequence.addingSaturating(1)
        let marker = LedgerEntry(
            id: EntryID(node: configuration.node, sequence: sequence),
            account: configuration.account,
            timestamp: stamp,
            kind: .accountMerged(from: other.account)
        )
        return try ledger.absorb(other, mergedAt: marker)
    }

    // MARK: Policy / region

    public func setRegion(_ region: Identifier?) { self.region = region }

    public func applyPolicyUpdate(_ update: JurisdictionPolicy) { policy = policy.applying(update: update) }

    public var activePolicy: JurisdictionPolicy { policy }

    // MARK: Evaluation

    private func reconciledAge() -> ReconciledAge {
        AgeSignalReconciler.reconcile(Array(signals.values), policy: configuration.reconciliation, nowMilliseconds: now())
    }

    /// Mints the next snapshot version synchronously.
    @discardableResult
    private func evaluateLocally() -> GateSnapshot {
        gateVersion = gateVersion.addingSaturating(1)
        let snapshot = CapabilityGate.snapshot(
            capabilities: configuration.capabilities,
            age: reconciledAge(),
            consent: ledger.fold(),
            region: region,
            policy: policy,
            version: gateVersion,
            producedAt: clock.tick(nowMilliseconds: now())
        )
        if let current = currentSnapshot, current.version >= snapshot.version {
            // Unreachable while versions are minted here; kept as the
            // invariant's guard rather than trusting the comment.
            return current
        }
        currentSnapshot = snapshot
        return snapshot
    }

    /// Evaluates every gate, stores the snapshot locally, then pushes it to
    /// the backend with bounded retries. The local decision is live the
    /// moment this method is entered; propagation failure never re-opens a
    /// gate that was closed locally.
    @discardableResult
    public func evaluateAndPublish() async -> Result<PropagationAck, PropagationError> {
        let snapshot = evaluateLocally()
        var attempt = 1
        while true {
            do {
                let ack = try await propagator.publish(snapshot, account: configuration.account)
                lastAcknowledged = lastAcknowledged.map { max($0, ack.accepted) } ?? ack.accepted
                // Only the ack for the *newest* minted snapshot may clear the
                // error: an older publish resolving after a newer one failed
                // must not hide that failure (actor reentrancy across the await).
                if let current = currentSnapshot, ack.accepted >= current.producedAt { lastPropagationError = nil }
                return .success(ack)
            } catch let error as PropagationError {
                switch error {
                case .staleVersion(let server, _):
                    // Fold the server's timestamp into our clock so the next
                    // snapshot this device mints sorts after what the server
                    // holds — otherwise a device with a slow clock could never
                    // publish again after a fast peer.
                    clock.receive(server, nowMilliseconds: now())
                    lastPropagationError = nil
                    return .failure(error)
                case .transport(let message):
                    lastPropagationError = message
                    if attempt >= configuration.retry.maximumAttempts { return .failure(error) }
                    await sleeper.sleep(milliseconds: configuration.retry.delay(beforeAttempt: attempt))
                    attempt = attempt.addingSaturating(1)
                }
            } catch {
                lastPropagationError = "\(error)"
                let wrapped = PropagationError.transport("\(error)")
                if attempt >= configuration.retry.maximumAttempts { return .failure(wrapped) }
                await sleeper.sleep(milliseconds: configuration.retry.delay(beforeAttempt: attempt))
                attempt = attempt.addingSaturating(1)
            }
        }
    }
}
