# Testing the Sfere iOS SDK

For developers and testers. To add the SDK to an app, see [`README.md`](README.md). The Android SDK lives in its own repository, [`sfere-io/sfere-android-sdk`](https://github.com/sfere-io/sfere-android-sdk), and sends the same payload.

## Status (2026-10-21)

Version `0.1.0`, the first public release ([`docs/ci-cd.md`](docs/ci-cd.md)). It installs from the public repository with no GitHub account.

| Area | State |
|---|---|
| iOS SDK | 45 unit tests pass. Runs in the sample app on the iOS Simulator, and every simulator flow passes (see [Simulator flows](#5-simulator-flows-automated)). |
| Same payload as Android | The shared parity scenario matches field by field (`tools/parity.sh`). |
| Staging | Not tested against the real ingestion endpoint yet. Everything so far runs against a local mock. |
| CI | Every pull request runs Swift style, Static analysis, Build, API contract, Tests & coverage and SonarQube ([`docs/ci-cd.md`](docs/ci-cd.md)). The simulator flows and the parity check still run by hand. |

## What you need

- macOS with Xcode 26 (Swift 5.9+).
- SwiftLint for the lint check: `brew install swiftlint`.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the sample app: `brew install xcodegen`.
- Node 18+ and Python 3 for the mock server and the scripts.

All commands below run from the repository root. In VS Code, the same commands are tasks: `Cmd+Shift+B` runs the unit tests, and *Terminal → Run Task* lists the rest.

## How to test

### 1. Unit tests

```sh
swift test
```

Expected: `Executed 45 tests, with 0 failures`.

### 2. Same payload as Android

This needs both repositories checked out side by side, `sfere-ios-sdk` and `sfere-android-sdk` in the same folder. It also needs everything the Android tests need (JDK 17, the Android SDK). Set `SFERE_IOS_SDK_DIR` and `SFERE_ANDROID_SDK_DIR` to use other locations.

```sh
tools/parity.sh
```

First it checks that the files both repositories share (`fixtures/`, the mock server, the parity scripts) are identical. Then it runs the same scenario on both SDKs and compares the upload bodies key by key. Expected: every shared file and every event reported as `same`, exit code 0.

### 3. Start the mock ingestion server

The sample app sends to a local mock of the ingestion endpoint, so you can see exactly what it sends.

```sh
tools/mock_ingest_ctl.sh start    # http://127.0.0.1:4320; running it twice reuses the server
tools/mock_ingest_ctl.sh stop
```

Useful routes while testing:

```sh
curl -s http://127.0.0.1:4320/__events | python3 -m json.tool    # everything received
curl -s -X POST http://127.0.0.1:4320/__reset                     # clear it
curl -s -X POST http://127.0.0.1:4320/__fail -d '{"status":503,"count":1}'   # next upload fails with 503
curl -s -X POST http://127.0.0.1:4320/__offline -d '{"offline":true}'        # drop connections like a dead network
curl -s -X POST http://127.0.0.1:4320/__offline -d '{"offline":false}'
```

### 4. Sample app (by hand)

```sh
xcodegen generate --spec Example/project.yml
open Example/SfereExample.xcodeproj
```

Run the `SfereExample` scheme on an iPhone simulator. The app sends to `http://127.0.0.1:4320` by default. The **Received by the mock** section at the bottom lists what the mock got (press *Refresh*).

- Each button sends one event: identify, screen, purchase and the GA4 e-commerce events, a custom event, and *send 200 queue_test_event* for the offline queue.
- The switches set consent and opt-out.
- *Settings* changes the host, key and session timeout. They apply on the next launch.
- Deep link: `xcrun simctl openurl booted "sfereexample://match/42?utm_source=test&gclid=abc"`. Accept the "Open in Sfere Sample?" prompt.
- Events sent while the app starts (`app_opened` and the others) go out on the flush interval, up to 30 seconds later. Events from buttons go out at once.

### 5. Simulator flows (automated)

One script boots a dedicated simulator (`Sfere Flows iPhone 16`, iOS 18.5), checks a fresh install and an upgrade with `simctl`, then runs the XCUITest flows in `Example/UITests` against the mock. At the end it shuts the simulator down, and it stops the mock if it started it. It takes about 10 minutes and uses a few GB of memory.

```sh
python3 -I tools/ios_flows.py
python3 -I tools/ios_flows.py --only-testing SfereExampleUITests/SampleAppFlowTests/testConsentChangeAppliesToTheNextEvent
```

What it checks:

- Fresh install: `app_installed`, `app_opened` and `session_started`, with no `context.device.id`.
- Upgrade: `app_updated` with `previous_version` and `version`.
- Deep links on a cold start and while running: `deep_link_opened`, then `context.clientIds.gclid` and `context.campaign` on later events.
- Consent: the next event carries `context.consent.categoryPreferences`.
- Identify, then reset: a new anonymous id, and no user id or traits.
- Opt-out: nothing is sent, and the choice is remembered after a relaunch.
- Server errors: 503 and 429 are retried, and 400 is dropped.
- Offline queue: 200 events queued offline survive a forced quit, then each arrives exactly once.
- Session: a new session and `session_started` after a 1-minute timeout in the background.

Expected last line: `simctl flows: 6/6 checks passed; UI tests passed`.

### 6. What to check in the payloads

For any event in `/__events`:

- It went to `POST /v1/batch/b` with `Authorization: Basic …`, and the body has `writeKey` and `batch`.
- Event names are snake_case (`app_opened`, `add_to_cart`, `deep_link_opened`).
- `context.library` is `{name, version, base}`, and `context.session.id` is present.
- These are never present: `_metadata`, an empty `integrations`, `context.instanceId`, `context.device.id`, `metrics`.
- Email and phone in `identify` traits are sent as given. The SDK never hashes them.
- No request goes anywhere except the configured host. A proxy such as Proxyman shows this.

## Reporting problems

Open an issue in this repository with:

- the iOS version, and whether it was a simulator or a device;
- the steps you took;
- the relevant part of `curl -s http://127.0.0.1:4320/__events`;
- the Xcode console log.

## Repository layout

| Path | What |
|---|---|
| `Package.swift` | The package manifest. It sits at the root so Swift Package Manager can install the package from this repository. |
| `Sources/SfereAnalytics`, `Tests/SfereAnalyticsTests` | The SDK and its unit tests |
| `Example` | Sample app (XcodeGen `project.yml`) and its UI tests |
| `fixtures/` | Test tables shared with the Android SDK (deep links, event names). The Android repository has an identical copy. |
| `tools/` | Mock ingestion server, simulator flow driver, parity check |
