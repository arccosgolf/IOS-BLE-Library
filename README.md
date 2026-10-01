# iOS-BLE-Library

![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20iPadOS%20|%20macOS-333333.svg)
[![License](https://img.shields.io/github/license/nordicsemi/IOS-BLE-Library)](https://github.com/nordicsemi/IOS-BLE-Library/blob/main/LICENSE)
[![Release](https://img.shields.io/github/release/nordicsemi/IOS-BLE-Library.svg)](https://github.com/nordicsemi/IOS-BLE-Library/releases)
[![GitHub stars](https://img.shields.io/github/stars/nordicsemi/IOS-BLE-Library)](https://github.com/nordicsemi/IOS-BLE-Library/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/nordicsemi/IOS-BLE-Library)](https://github.com/nordicsemi/IOS-BLE-Library/members)
[![GitHub contributors](https://img.shields.io/github/contributors/nordicsemi/IOS-BLE-Library)](https://github.com/nordicsemi/IOS-BLE-Library/graphs/contributors)

This library is a wrapper around the [CoreBluetooth](https://developer.apple.com/documentation/corebluetooth/) framework which provides a modern async API based on [Combine](https://developer.apple.com/documentation/combine).

# Library Versions

The package ships **two products**, and consumers pick the one that fits their needs:

- `iOS-BLE-Library` — links real [`CoreBluetooth`](https://developer.apple.com/documentation/corebluetooth/). For production apps.
- `iOS-BLE-Library-Mock` — links [`CoreBluetoothMock`](https://github.com/nordicsemi/IOS-CoreBluetooth-Mock). The public API is identical (a top-level `Alias.swift` re-exports `CB*` names for the underlying `CBM*` types), so code written for `iOS-BLE-Library` recompiles unchanged against `iOS-BLE-Library-Mock` for unit testing.

# Architecture

Both products are built from a single source tree at `Sources/iOS-BLE-Library/`. The Mock target's compilation unit is produced at build time by the `MockGenerator` SwiftPM build plugin — there are no Python scripts, no committed duplicates, no manual sync step.

At the handful of sites where the two products diverge (mostly imports, plus a couple of init-time branches), the source uses native Swift conditional compilation:

```swift
#if MOCK_TRANSPORT
import CoreBluetoothMock
#else
import CoreBluetooth
#endif
```

The Mock target sets `swiftSettings: [.define("MOCK_TRANSPORT")]`; the native target leaves the flag undefined. The compiler picks the right branch per build.

## For contributors

1. Edit files only in `Sources/iOS-BLE-Library/`. Do not edit anything under `Sources/iOS-BLE-Library-Mock/` (other than `Alias.swift` and `Documentation.docc/`, which are static).
2. For code that needs to behave differently in the Mock build, wrap it in `#if MOCK_TRANSPORT … #else … #endif`.
3. Run `swift build` — the plugin re-generates the Mock target's sources automatically.

That's the whole workflow. No `code_gen` step, no marker DSL.

# Installation

## Swift Package Manager

Add the package to your `Package.swift` dependencies and pick the product you need:

```swift
let package = Package(
    // ...
    dependencies: [
        .package(url: "https://github.com/nordicsemi/IOS-BLE-Library.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                // Production: links real CoreBluetooth
                .product(name: "iOS-BLE-Library", package: "IOS-BLE-Library")
            ]
        ),
        .testTarget(
            name: "MyAppTests",
            dependencies: [
                "MyApp",
                // Testing: links CoreBluetoothMock
                .product(name: "iOS-BLE-Library-Mock", package: "IOS-BLE-Library")
            ]
        ),
    ]
)
```

# Documentation & Examples

Please check the [Documentation Page](https://nordicsemi.github.io/IOS-BLE-Library/documentation/ios_ble_library/) to start using the library.

Also you can check [iOS-nRF-Toolbox](https://github.com/nordicsemi/IOS-nRF-Toolbox/tree/develop) to find more examples.

# Special Thanks

Please consider backing this project by using the following **GitHub Sponsor** button.

We want to [thank all of our contributors](https://github.com/nordicsemi/IOS-BLE-Library/graphs/contributors) for all of their additions and improvements to this project. With special mention to one in particular: [Nick!](https://github.com/NickKibish)

<a href="https://github.com/nordicsemi/IOS-BLE-Library/graphs/contributors">
  <img src="https://contributors-img.web.app/image?repo=nordicsemi/IOS-BLE-Library" />
</a>

# Arccos fork

This repository is Arccos's fork of Nordic's library; the golf app consumes it as the
`IOSBLELibrary` product. Upstream's file layout is kept so upstream merges apply cleanly,
and Arccos-specific behaviour is marked with `// Arccos:` comments.

## Running the tests

```sh
# macOS host, ~1 minute. CI runs the same suite through xcodebuild (below, with
# `-destination 'platform=macOS'`) so a hung test is killed and named.
swift test

# iOS Simulator. Also covers the `#if !os(macOS)` paths a host build never compiles.
# Use any iPhone from `xcrun simctl list devices available`.
xcodebuild test -scheme IOSBLELibrary-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation -skipMacroValidation
```

Tests live in `Tests/iOS-BLE-LibraryTests` and run against `iOS-BLE-Library-Mock`
([CoreBluetoothMock](https://github.com/nordicsemi/IOS-CoreBluetooth-Mock)), never a real
radio. `Support/` is the shared harness:

- `CentralManagerTestCase` owns the simulation lifecycle and the scan / connect /
  expect-disconnect helpers every scenario starts with. Its `makeCentral(restoreIdentifier:)`
  drives state restoration: CoreBluetoothMock delivers `willRestoreState` synchronously
  inside the manager's initializer, the same timing as CoreBluetooth.
- `SimulatedPeripheral` is a configurable simulated device (services, discovery latency via
  `connectionInterval`, discovery failures, request hooks and counters).
- `withTimeout` bounds an `await` so a hang fails one test instead of the suite. Use it
  around any library call that can hang; that is this library's main defect class.

CoreBluetoothMock keeps process-wide state, so tests run serially. Do not pass
`--parallel`. CI (`.github/workflows/ci.yml`) runs both commands above on every pull request.

Tests wrapped in `XCTExpectFailure { }` document a known defect that is scheduled but not
yet fixed. When the fix lands, remove the wrapper; XCTest fails a test that unexpectedly
passes, so a stale marker cannot go unnoticed. Keep the assertions inside the closure:
expected-failure matching is thread-scoped and does not survive an `await`.

## Connecting: say what happens when you let go

`CentralManager.connect(_:options:keepPendingOnAbandon:)` has no default for its last
argument. CoreBluetooth's connect request never times out, and the publisher only observes
it, so every call site states what the request does when the subscription ends:

- `keepPendingOnAbandon: true`: the request (or the connection) outlives the publisher. Use
  this when you await the connect (`firstValue`, a Combine `timeout`) and disconnect through
  `cancelPeripheralConnection`. This is how the library always behaved, and how the app connects.
- `keepPendingOnAbandon: false`: the subscription owns the connection; when it ends, by
  cancellation or completion, the request is withdrawn. Never pair it with `firstValue`.

`connectInventory` / `pendingConnects` list the connects CoreBluetooth currently holds for
the app (issued here, or handed back by state restoration), read from the handles' own
`state`. Every other publisher undoes its side effect when its subscription is cancelled: a
scan stops the radio, a discovery request still queued behind another is withdrawn.

## Nothing happens until you subscribe

Every publisher the library returns is cold: the CoreBluetooth request (`connect`,
`cancelPeripheralConnection`, `scanForPeripherals`, every `Peripheral` operation) is issued
when the first subscriber arrives, not when the method returns. `let _ =
centralManager.connect(...)` compiles, logs nothing and issues nothing; that shape sat in the
app's background-monitoring connect path for its entire life (A9, app PR #1824). Subscribe
where you create the publisher (`sink`, `firstValue`, `values`) and hold the subscription for
as long as you want to hear about the operation.

Since Wave C4 a publisher released without ever being subscribed reports itself to
`BluetoothPublisherDiagnostics.onDroppedUnsubscribed` with the operation it stood for and how
long it was held. The default handler logs the report at fault level through `Logger.shared`
and calls `assertionFailure`, so a debug build stops on the offending release and a release
build only logs. Replace the handler at launch to route reports into your own logging or
telemetry. A publisher that was subscribed is never reported, whether its subscription is
still live, was cancelled, or completed.

## Shipping a change to the app

Feature flags cannot reach inside an SPM package, so the pin is the release unit:

1. Land the fork change together with its unit tests.
2. Tag it `arccos-<upstream version>-<n>` (for example `arccos-0.4.5-rebase`, then
   `arccos-0.4.5-1`). The release workflow builds and tests the tag.
3. Bump the app's pin to that tag. Pin by tag or revision, never by branch, and ship one
   behaviour change per bump so a regression rolls back by re-pinning the previous tag.
