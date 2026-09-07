# ConsentLedger

**Age assurance on iOS is not two SDK calls. It is a distributed-state problem, and this is the state machine, the ledger and the gate that solve it.**

`DeclaredAgeRange` gives you an age *bracket* on the device. Your backend has an account age. A guardian has (or has not) completed a consent flow on a *different* device with a *different* clock. Those three signals disagree, arrive out of order, go stale at different rates, and the answer they produce has to be identical on every device the child owns, survive an account merge, propagate to your server-side feature flags, and — in every jurisdiction including the one you have never heard of — fail **closed**.

`ConsentLedger` is a Swift package that turns that into code you can defend in a review:

| Layer | Type | What it decides |
|---|---|---|
| Signals | `AgeSignalProvider` · `AgeSignalReconciler` | Which bracket the gate may believe, when three sources disagree |
| Facts | `Ledger` · `ConsentState` | The append-only, mergeable consent log and the state machine folded from it |
| Policy | `JurisdictionPolicy` · `CapabilityRule` | What each region requires, with unknown = strictest and remote updates that can only tighten |
| Gate | `CapabilityGate` · `GateSnapshot` | The one place a feature asks "may I?" — never a raw age check |
| Propagation | `GatePropagator` · `ConsentOrchestrator` | Getting the same answer onto the backend, monotonically, from N devices |
| Proof | `ConvergenceAudit` · `FailClosedAudit` | Ships in the library; each runs against a deliberately broken implementation in the tests and must fail |

The demo app runs two of these side by side (a child's iPad and a guardian's iPhone, clocks 90 s apart) against one in-memory backend, so you can watch a revocation on one device close a gate on the other after a sync.

- **Demo app:** [`consent-ledger-kit-demo-app`](https://github.com/rajatslakhina/consent-ledger-kit-demo-app) — a separate `Demo.xcodeproj` that consumes this package as a remote, version-pinned dependency.

## Why this matters

The September 2026 App Store age-assurance deadline moves this from "nice to have" to "reject on review". Most codebases will meet it the obvious way: call the platform API on launch, cache the bracket, write `if age < 13 { hide(feature) }` in forty places. That ships. Then a guardian revokes consent on their phone, the child's iPad is offline, the account gets merged with a guest session that had chat revoked, and remote config gets a typo that flips a region to `minimumAge: 0`. Every one of those is a real ticket, and none of them is answerable when the age check is a scattered `if`.

An engineering lead's job here is to pick the *shape* that makes those tickets impossible rather than merely unlikely: one module boundary every feature goes through, one log that every device can merge without coordination, one rule for what "unknown" means. That is what this package is.

## Design decisions (and what they cost)

**1. Disagreement never makes the child older.**
`AgeSignalReconciler` produces two brackets. `attested` is the highest-trust fresh source, for the UI. `conservative` is the intersection of all fresh sources — or, when they are disjoint, the *youngest* one — and it is the only bracket `CapabilityGate` reads. A server record saying 18+ does not outrank a device declaring under-13; only a `guardianAttestation` (the resolution mechanism, not a party to the dispute) can raise the conservative bracket.
*Cost:* a wrong self-declaration locks an adult out until a higher-trust source resolves it. That is the correct failure direction for a consumer app and the wrong one for nothing.

**2. The ledger is a state-based CRDT; the state machine is a pure fold.**
Every fact (`ageDeclared`, `consentGranted`, `consentRevoked`, `accountMerged`, …) is a `LedgerEntry` with a hybrid logical timestamp and a `(node, sequence)` identity. `Ledger.merge` is set union; `Ledger.fold` sorts by a total order and applies `ConsentState.apply`. Merge is commutative, associative and idempotent by construction (tested), so out-of-order delivery, duplicates and replay all converge.
*Cost:* the log grows. See decision 4.

**3. Ties fail closed — by ordering, not by special case.**
Two devices act in the same HLC millisecond: the guardian grants on the iPhone, someone revokes on the iPad. The fold order sorts `consentRevoked` *after* `consentGranted` within an instant (`ConsentEventKind.tieBreakRank`), so the revocation is applied last and wins, whatever the node names are. A revocation is also the one event the reducer never rejects: recording "no" before the age is known only ever closes gates.
*Rejected alternative:* last-writer-wins by wall clock. Two phones do not share a clock; the demo's guardian device deliberately runs 90 seconds fast to make the point.

**4. Compaction is the owner's decision, never the value type's.**
A compacted entry is no longer shipped by `merge`, so folding it into the snapshot before a peer has it breaks convergence. `Ledger` therefore only *reports* `needsCompaction`; `ConsentOrchestrator.compactIfSafe()` compacts only entries a peer has acknowledged, and only the contiguous-per-node prefix that cannot be re-ordered by a late arrival. Growth is bounded by `Limits.hardCapacity`; a merge that would exceed it is refused whole (`LedgerError.capacityExceeded`), leaving the ledger intact.
*Cost:* a device that never syncs never compacts. It also never loses a fact, which is the right trade for a consent log.

**5. Account merge replays facts, not state — and is fail-closed past the horizon.**
`Ledger.absorb` re-homes every fact from the other account (its compacted snapshot's age facts and guardian decisions, plus its tail) as *synthetic* entries with their original timestamps and deterministic, timestamp-derived IDs (`EntryID.synthetic(for:)`), so absorbing twice is a no-op, the guest account's chat revocation survives the merge, and a guest written on the *same device* (same node, sequences restarting at 1) cannot overwrite the signed-in account's own entries. If this ledger has already compacted past the guest's history, older facts cannot be folded in order any more: grants are **dropped** (a grant moved later in history could re-open a gate a folded revocation closed), revocations are re-timestamped to the merge instant (moving a "no" later only closes gates), and the caller gets an `AbsorbReport` saying so. Synthetic IDs are unique through the year 2109; beyond that `absorb` refuses rather than silently discarding a decision.
*Rejected alternative:* merging folded `ConsentState` values. There is no correct merge of two states without their history.

**6. Unknown region = the meet of every known rule. Remote updates can only tighten.**
`JurisdictionPolicy.rule(for:in:)` returns the most-restrictive combination (`CapabilityRule.meet`, a semilattice, so order cannot matter) when the region is `nil` or unlisted. `applying(update:)` meets each remote rule with the compiled-in one and ignores regions the binary does not know: an unknown region is already at the strictest rule, so "recognising" it remotely could only loosen it — that change ships through App Review, not a config push.

**7. The gate is never stale, and propagation is monotone on an HLC, not on a version counter.**
Every mutation on `ConsentOrchestrator` — an observed signal, a consent change, a merged peer entry, an absorbed account, a region or policy change — invalidates the cached `GateSnapshot`, so `decision(for:)` re-evaluates on the next call: a revocation recorded locally closes the gate immediately, publish or no publish (`testDecisionReflectsEveryMutationWithoutAPublish`).
Two devices publishing "version 3" is exactly the collision that makes last-writer-wins wrong. `GateSnapshot.producedAt` is an HLC timestamp; the backend (`InMemoryGateServer` is the reference) rejects anything older than what it holds, and a rejected device folds the server's timestamp into its own clock so it can publish again. `ConsentOrchestrator.evaluateAndPublish` mints the snapshot *before* its first `await`, so overlapping calls never regress local state; transport failures retry on an injectable schedule, and a failed publish never re-opens a gate that closed locally.

**8. No trapping arithmetic reachable from the public API.**
Every counter goes through `addingSaturating` / `multipliedSaturating`; `WallClock.milliseconds(fromSeconds:)` clamps NaN and infinities instead of `Int64(Double)`; `AgeBracket` and `Identifier` are failable on construction *and* on decode; `RetryPolicy.delay` is bounds-checked past the end of the schedule; `AgeBracket` constants are literals with a tested fallback rather than force-unwraps. There is no force-unwrap, `try!` or `as!` in `Sources/`.

## What is deliberately *not* here

- **A birthdate.** No API takes or stores one. Brackets only, as the platform intends.
- **The real `DeclaredAgeRange` call.** `ClosureAgeSignalProvider` is the seam; the closure that calls `AgeRangeService` lives in the app so the package stays Linux-testable.
- **A remote-region allow-list.** See decision 6.
- **A "skip consent for now" path.** `FailClosedAudit` treats one as a violation, and the test proves it catches it.

## How to use it

```swift
dependencies: [
    .package(url: "https://github.com/rajatslakhina/consent-ledger-kit.git", from: "1.0.2")
]
```

```swift
import ConsentLedger

let policy = JurisdictionPolicy(version: 1, rules: [...], baseline: CapabilityRule(minimumAge: 13, guardianConsentBelow: nil))
let orchestrator = ConsentOrchestrator(
    configuration: OrchestratorConfiguration(node: "child-ipad", account: "acct-123", policy: policy, region: "GB"),
    providers: [ClosureAgeSignalProvider(source: .declaredRange) { /* call AgeRangeService, map to AgeBracket */ }],
    propagator: MyFeatureFlagClient()
)
await orchestrator.refreshSignals()
await orchestrator.evaluateAndPublish()

switch await orchestrator.decision(for: .generativeFeatures) {
case .allowed(let consentBy): showAssistant()
case .denied(.consentRequired): askGuardian()
case .denied(let reason): hide(reason)
}
```

Features import `CapabilityGate`'s decision. They never import an age.

## Verification

This section is written against what actually ran, not what should have.

- **Linux, Swift 6.0.3:** `rm -rf .build && swift build -Xswiftc -warnings-as-errors` → `Build complete!` with zero warnings; `swift build --build-tests -Xswiftc -warnings-as-errors && swift test` → **70 tests, 0 failures** across `PrimitiveTests` (15), `ReconciliationTests` (10), `LedgerTests` (20), `GateTests` (8), `OrchestratorTests` (11), `AuditTests` (6).
- **Negative controls in the suite:** `ConvergenceAudit` must *fail* on `arrivalOrderFold`; `FailClosedAudit` must *fail* on the optimistic evaluator and on a "we'll ask later" consent bypass; a same-instant grant/revoke must fold to revoked with the node names in either order; a merge past `hardCapacity` must throw and leave the ledger untouched; a publish held open across a real suspension while the state changes must come back `staleVersion`, never overtake the newer snapshot.
- **CI:** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs the Linux job above on every push (warnings-as-errors is enforced there, not asserted in prose) and a macOS job that compiles `ConsentLedgerUI` for `generic/platform=iOS Simulator`. The Actions tab is the source of truth for the current status.
- **Simulator:** this package contains no app. The companion demo app was **built** for `generic/platform=iOS Simulator` by its CI, but it was **not run** on a Simulator during the scheduled run that produced these repos — `request_access` to Xcode/Simulator was refused three times ("can't be approved during a scheduled run"), so no screenshots exist anywhere. The demo README carries the verbatim refusal.

## Layout

```
Sources/ConsentLedger/       Primitives · AgeSignal · ConsentStateMachine · Ledger · CapabilityGate · Propagation · ConsentOrchestrator · Audit
Sources/ConsentLedgerUI/     ConsentOrchestrationDemoView (SwiftUI; empty target on Linux)
Tests/ConsentLedgerTests/    70 XCTest cases, including the negative controls above
```

No executable target. The runnable app lives in the companion repo and consumes this package as a version-pinned remote dependency.

## License

MIT — see [LICENSE](LICENSE).
