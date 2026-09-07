#if canImport(SwiftUI)
import SwiftUI
import ConsentLedger

// MARK: - Simulation model

/// Two devices, one backend. The child's iPad and the guardian's iPhone each
/// run their own `ConsentOrchestrator` against the same `InMemoryGateServer`;
/// "Sync" exchanges ledger entries in both directions the way a real sync
/// layer would. Every button is a real call into the library — nothing here
/// is mocked past the transport.
@MainActor
public final class ConsentSimulation: ObservableObject {
    public struct DeviceView: Equatable {
        public var name: String
        public var status: OrchestratorStatus?
    }

    @Published public private(set) var child = DeviceView(name: "Child · iPad", status: nil)
    @Published public private(set) var guardian = DeviceView(name: "Guardian · iPhone", status: nil)
    @Published public private(set) var serverSnapshot: GateSnapshot?
    @Published public private(set) var log: [String] = []
    @Published public var region: String = "US" {
        didSet { Task { await applyRegion() } }
    }

    public let regions: [String]
    public let policy: JurisdictionPolicy
    public let capabilities: [Capability]

    private let server = InMemoryGateServer()
    private let childDevice: ConsentOrchestrator
    private let guardianDevice: ConsentOrchestrator
    private let guardianID: Identifier
    private let account: Identifier
    private var mergedGuest = false

    /// Ordering-only clock offset so the two devices visibly disagree on wall
    /// time (the guardian's phone runs 90 s fast) — HLC ordering still holds.
    private static let guardianSkewMilliseconds: Int64 = 90_000

    public init(policy: JurisdictionPolicy, capabilities: [Capability], regions: [String]) {
        self.policy = policy
        self.capabilities = capabilities
        self.regions = regions.isEmpty ? ["US"] : regions
        let region = Identifier(validating: self.regions.first ?? "US")
        let childNode: Identifier = "child-ipad"
        let guardianNode: Identifier = "guardian-iphone"
        let account: Identifier = "acct-child-001"
        self.account = account
        self.guardianID = "guardian-maya"

        let childConfiguration = OrchestratorConfiguration(
            node: childNode, account: account, capabilities: capabilities, policy: policy, region: region
        )
        let guardianConfiguration = OrchestratorConfiguration(
            node: guardianNode, account: account, capabilities: capabilities, policy: policy, region: region
        )
        let skew = ConsentSimulation.guardianSkewMilliseconds
        childDevice = ConsentOrchestrator(configuration: childConfiguration, providers: [], propagator: server)
        guardianDevice = ConsentOrchestrator(
            configuration: guardianConfiguration,
            providers: [],
            propagator: server,
            now: { WallClock.nowMilliseconds().addingSaturating(skew) }
        )
        Task { await refresh() }
    }

    // MARK: Actions

    public func declareOnChild(_ bracket: AgeBracket) {
        Task {
            await run("Child declares \(bracket)") { try await self.childDevice.observe(source: .declaredRange, bracket: bracket) }
        }
    }

    public func serverVerifies(_ bracket: AgeBracket) {
        Task {
            await run("Account record says \(bracket)") { try await self.childDevice.observe(source: .serverAccountAge, bracket: bracket) }
        }
    }

    public func requestConsent() {
        Task {
            await run("Child requests consent from \(guardianID)") {
                try await self.childDevice.requestConsent(from: self.guardianID, scope: .all)
            }
        }
    }

    public func guardianGrants(scope: ConsentScope) {
        Task {
            await run("Guardian grants \(ConsentSimulation.describe(scope))") {
                try await self.guardianDevice.grantConsent(guardian: self.guardianID, scope: scope)
            }
        }
    }

    public func guardianRevokes() {
        Task {
            await run("Guardian revokes all") {
                try await self.guardianDevice.revokeConsent(guardian: self.guardianID, scope: .all)
            }
        }
    }

    public func guardianAttests(_ bracket: AgeBracket) {
        Task {
            await run("Guardian attests \(bracket)") {
                try await self.guardianDevice.observe(source: .guardianAttestation, bracket: bracket)
            }
        }
    }

    /// Exchanges entries both ways, acknowledges, and compacts if safe.
    public func sync() {
        Task {
            await run("Sync child ⇄ guardian") {
                let fromChild = await self.childDevice.exportEntries()
                let fromGuardian = await self.guardianDevice.exportEntries()
                try await self.guardianDevice.importEntries(fromChild)
                try await self.childDevice.importEntries(fromGuardian)
                await self.childDevice.acknowledge(fromChild.map(\.id) + fromGuardian.map(\.id))
                await self.guardianDevice.acknowledge(fromChild.map(\.id) + fromGuardian.map(\.id))
                _ = await self.childDevice.compactIfSafe()
                _ = await self.guardianDevice.compactIfSafe()
            }
        }
    }

    /// Simulates a guest account (used before sign-in) in which a *different*
    /// guardian had revoked chat, being merged into the signed-in account.
    /// Because any guardian's revocation beats any other guardian's grant,
    /// chat stays closed on the merged account even if Maya later grants all.
    public func mergeGuestAccount() {
        guard !mergedGuest else { return }
        mergedGuest = true
        Task {
            await run("Merge guest account (guardian-omar had revoked chat)") {
                let guestAccount: Identifier = "acct-guest-777"
                let guestNode: Identifier = "guest-device"
                let otherGuardian: Identifier = "guardian-omar"
                let chat = Capability.chat.id
                var guest = Ledger(account: guestAccount)
                var clock = HybridClock(node: guestNode)
                let base = WallClock.nowMilliseconds().subtractingSaturating(3_600_000)
                try guest.append(LedgerEntry(
                    id: EntryID(node: guestNode, sequence: 1), account: guestAccount,
                    timestamp: clock.tick(nowMilliseconds: base), kind: .ageDeclared(.under13)
                ))
                try guest.append(LedgerEntry(
                    id: EntryID(node: guestNode, sequence: 2), account: guestAccount,
                    timestamp: clock.tick(nowMilliseconds: base.addingSaturating(1)), kind: .consentRevoked(guardian: otherGuardian, scope: .capabilities([chat]))
                ))
                let report = try await self.childDevice.absorb(guest)
                if report.grantsDropped > 0 || report.revocationsRetimestamped > 0 {
                    self.append("  ↳ merged past compaction horizon: \(report.revocationsRetimestamped) revocation(s) re-timestamped, \(report.grantsDropped) grant(s) dropped")
                }
            }
        }
    }

    // MARK: Internals

    private func applyRegion() async {
        let identifier = Identifier(validating: region)
        await childDevice.setRegion(identifier)
        await guardianDevice.setRegion(identifier)
        await run("Region → \(region)") {}
    }

    private func run(_ label: String, _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            append("✓ \(label)")
        } catch {
            append("✗ \(label): \(error)")
        }
        await refresh()
    }

    private func refresh() async {
        _ = await childDevice.evaluateAndPublish()
        _ = await guardianDevice.evaluateAndPublish()
        child.status = await childDevice.status
        guardian.status = await guardianDevice.status
        serverSnapshot = await server.snapshot(for: account)
    }

    private func append(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    static func describe(_ scope: ConsentScope) -> String {
        switch scope {
        case .all: return "all capabilities"
        case .capabilities(let set): return set.map(\.rawValue).sorted().joined(separator: ", ")
        }
    }
}

// MARK: - View

public struct ConsentOrchestrationDemoView: View {
    @StateObject private var simulation: ConsentSimulation

    public init(policy: JurisdictionPolicy, capabilities: [Capability] = Capability.standardSet, regions: [String]) {
        _simulation = StateObject(wrappedValue: ConsentSimulation(policy: policy, capabilities: capabilities, regions: regions))
    }

    public var body: some View {
        NavigationStack {
            List {
                regionSection
                deviceSection(simulation.child)
                deviceSection(simulation.guardian)
                actionsSection
                logSection
            }
            .navigationTitle("Consent Ledger")
        }
    }

    private var regionSection: some View {
        Section("Jurisdiction") {
            Picker("Region", selection: $simulation.region) {
                ForEach(simulation.regions, id: \.self) { Text($0) }
                Text("Unknown").tag("??")
            }
            .pickerStyle(.segmented)
            LabeledContent("Policy version", value: "\(simulation.policy.version)")
            LabeledContent("Server holds snapshot", value: simulation.serverSnapshot.map { "\($0.producedAt)" } ?? "—")
        }
    }

    private func deviceSection(_ device: ConsentSimulation.DeviceView) -> some View {
        Section(device.name) {
            if let status = device.status {
                LabeledContent("Phase", value: status.consent.phase.rawValue)
                LabeledContent("Conservative age", value: status.age.conservative.map { "\($0)" } ?? "unknown")
                if let attested = status.age.attested {
                    LabeledContent("Attested by", value: "\(attested.source.rawValue) · \(attested.bracket)")
                }
                if !status.age.disagreements.isEmpty {
                    Label("\(status.age.disagreements.count) source disagreement(s) — gate uses the youngest bracket", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !status.age.staleSources.isEmpty {
                    Text("Stale: \(status.age.staleSources.map(\.rawValue).joined(separator: ", "))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(simulation.capabilities) { capability in
                    HStack {
                        Text(capability.displayName)
                        Spacer()
                        decisionLabel(status.snapshot.decision(for: capability.id))
                    }
                }
                LabeledContent("Ledger tail", value: "\(status.ledgerTailCount) entries · v\(status.snapshot.version)")
                if let error = status.lastPropagationError {
                    Text("Propagation: \(error)").font(.footnote).foregroundStyle(.red)
                }
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func decisionLabel(_ decision: GateDecision) -> some View {
        switch decision {
        case .allowed(let guardian):
            Label(guardian.map { "consent · \($0)" } ?? "allowed", systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(.green)
        case .denied(let reason):
            Label(reason.rawValue, systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.red)
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button("Child declares under 13") { simulation.declareOnChild(.under13) }
            Button("Child declares 13–15") { simulation.declareOnChild(.thirteenToFifteen) }
            Button("Account record says 13–15") { simulation.serverVerifies(.thirteenToFifteen) }
            Button("Child requests consent") { simulation.requestConsent() }
            Button("Guardian grants all") { simulation.guardianGrants(scope: .all) }
            Button("Guardian grants chat only") { simulation.guardianGrants(scope: .capabilities([Capability.chat.id])) }
            Button("Guardian revokes all", role: .destructive) { simulation.guardianRevokes() }
            Button("Guardian attests under 13") { simulation.guardianAttests(.under13) }
            Button("Sync devices ⇄") { simulation.sync() }
            Button("Merge guest account") { simulation.mergeGuestAccount() }
        }
    }

    private var logSection: some View {
        Section("Log") {
            if simulation.log.isEmpty {
                Text("No actions yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(simulation.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote.monospaced())
            }
        }
    }
}
#endif
