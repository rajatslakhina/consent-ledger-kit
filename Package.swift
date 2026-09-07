// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "consent-ledger-kit",
    // Only platforms CI actually builds are declared. Linux needs no declaration;
    // the demo app's CI builds for `generic/platform=iOS Simulator`.
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ConsentLedger", targets: ["ConsentLedger"]),
        .library(name: "ConsentLedgerUI", targets: ["ConsentLedgerUI"])
    ],
    targets: [
        .target(name: "ConsentLedger"),
        .target(name: "ConsentLedgerUI", dependencies: ["ConsentLedger"]),
        .testTarget(name: "ConsentLedgerTests", dependencies: ["ConsentLedger"])
    ]
)
