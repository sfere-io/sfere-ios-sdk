# Sfere iOS SDK

The Sfere iOS SDK. It collects first-party fan events in iOS apps and sends them to the Sfere ingestion endpoint. It wraps Segment's open-source `analytics-swift` unmodified, the same library Jitsu uses. Sfere's behaviour is added on top as plugins.

- **Sibling repo:** the Android SDK is `fanfinity/sfere-android-sdk`, checked out at `~/Desktop/Projects/sfere-android-sdk`. Until 2026-10-18 both lived in one repo, `fanfinity/sfere-mobile-sdks`, which is now deleted from GitHub. The two were split because apps integrate them differently. The old local folder `~/Desktop/Projects/sfere-mobile-sdks` was deleted too.
- **Payload contract:** `docs/WIRE-CONTRACT.md` and `docs/EVENTS.md` in the private repo `fanfinity/sfere-sdk`. Read them with `gh api 'repos/fanfinity/sfere-sdk/contents/<path>' -H 'Accept: application/vnd.github.raw'`; `gh repo clone` fails on this machine.
- **Plan and next steps:** `docs/mobile/sfere-mobile-sdks-plan.html` and `docs/mobile/sfere-mobile-sdks-next-steps.html` in `fanfinity/sfere-sdk`. They cover both platforms. Read them with `gh api 'repos/fanfinity/sfere-sdk/contents/docs/mobile/<file>' -H 'Accept: application/vnd.github.raw'`. Change them through a docs PR in that repo. The vendor name of the ingestion platform never appears there. Read the next-steps page at the start of every session. It has the ordered steps with their status, the user's decisions Q1–Q9, and the `#decision-record` JSON block. Copy the user's answers into that block and mark steps done there.
- **GitHub:** private repo `fanfinity/sfere-ios-sdk`. `origin` uses HTTPS because no SSH key is loaded. Push with `git -c credential.helper='!gh auth git-credential' push`, or run `gh auth setup-git` once.

## Layout

| Path | What |
|---|---|
| `README.md` | Integration guide for app developers. |
| `TESTING.md` | For developers and testers: status, prerequisites, and how to test (unit tests, parity, mock, sample app, simulator flows). Keep its status table and test counts current. |
| `Package.swift` | Package manifest. It must stay at the repo root, because SPM only installs packages whose manifest is at the root. Uses the default `Sources/` and `Tests/` paths. |
| `Sources/SfereAnalytics/` | The SDK. `Sfere.swift` (public API), `SfereTransport.swift` (inline settings, local settings answer, Basic auth), `Plugins/SferePlugins.swift` (rename, enrichment, sanitizer), `DeepLinkParser.swift`, `SfereState.swift`, `PrivacyInfo.xcprivacy` |
| `Tests/SfereAnalyticsTests/` | XCTest. `WireTests.swift` runs the real base library and checks the captured HTTP bodies |
| `Example/` | Sample app (SwiftUI). `project.yml` is the XcodeGen spec; the generated `SfereExample.xcodeproj` is git-ignored. Debug builds allow HTTP to local addresses only (`Info-Debug.plist`). Default host `http://127.0.0.1:4320`, deep-link scheme `sfereexample://` |
| `Example/UITests/` | XCUITest flows for phase D2 (`SampleAppFlowTests`). They read the mock's `/__events` directly. |
| `tools/mock_ingest.mjs` | Mock ingestion endpoint for the sample app (Node, no dependencies): `/v1/batch/b`, `GET /__events`, `POST /__reset`, `POST /__fail {status, count, retryAfter}`, gzip bodies. Port 4320 or `SFERE_MOCK_PORT`. Start and stop it with `tools/mock_ingest_ctl.sh start|stop|status`. |
| `tools/ios_flows.py` | Phase D2 driver: a dedicated simulator `Sfere Flows iPhone 16` (iOS 18.5), fresh install and upgrade through `simctl`, then the XCUITest flows. Work files go to `$TMPDIR/sfere-ios-flows`. |
| `tools/parity.sh`, `tools/parity_diff.py` | Cross-repo parity check: verifies the shared files are identical in both repos, runs both parity tests, and compares the upload bodies key by key. Exits non-zero on any difference. |
| `fixtures/` | `deeplinks.json` (URL → `clientIds` / `campaign`) and `event-names.json` (base names → Sfere names). The Android repo has an identical copy. |

## Run commands

| Task | Command | VS Code |
|---|---|---|
| Unit tests | `swift test` | `iOS: test` (default build task, `Cmd+Shift+B`) |
| Compile for iOS | `xcodebuild build -quiet -scheme SfereAnalytics -destination 'generic/platform=iOS Simulator'` | `iOS: build for Simulator` |
| Sample app | `xcodegen generate --spec Example/project.yml && xcodebuild build -quiet -project Example/SfereExample.xcodeproj -scheme SfereExample -destination 'generic/platform=iOS Simulator'` | `iOS: build sample app` |
| Mock ingestion server | `tools/mock_ingest_ctl.sh start` / `stop` (safe to run twice; stop kills only the PID on the port after checking it is the mock) | `Mock ingest: start` / `Mock ingest: stop` |
| Simulator flows (heavy: check memory first) | `python3 -I tools/ios_flows.py` (`--only-testing <test>`, `--skip-ui-tests`, `--keep-booted`). Shuts the simulator down and stops the mock if it started it. | `iOS: simulator flows` |
| iOS vs Android payloads | `tools/parity.sh` (needs `../sfere-android-sdk`, or `SFERE_ANDROID_SDK_DIR`). It runs Gradle, so stop the daemons after with `./gradlew --stop` in the Android repo. | `Parity: compare iOS and Android payloads` |

- `Package.resolved` is committed.
- The tests use write keys starting with `sferetest`. The base library makes a UserDefaults suite per key, and the tests delete those suites in `removeTestPreferenceSuites()`. cfprefsd sometimes writes a few empty 42-byte suite files back after the test ends; the next run's class `setUp` deletes them. Never widen the sweep beyond the `sferetest` prefix.

## Rules the code follows

- **Wire shape:**
  - Uploads go to `POST {host}/v1/batch/b` with `Authorization: Basic base64("writeKey:")`, and the batch body also carries `writeKey`.
  - No `_metadata`, no empty `integrations` and no `context.instanceId` on the wire. Each extra key becomes a warehouse column (full list below).
  - Only the allowed `clientIds` keys are sent (the list is in `fixtures/deeplinks.json`).
- **No third-party hosts:**
  - Settings are inline, and a custom `HTTPSession` answers the settings request locally.
  - Segment telemetry is turned off.
  - Tests assert that the only request goes to `{host}`.
- **Event names:**
  - GA4-style snake_case, decided 2026-10-13. Base lifecycle names are renamed: `Application Opened` → `app_opened`, and so on.
  - The SDK adds `session_started`.
  - E-commerce uses the GA4 keys from EVENTS.md.
- **No hashing:** the SDK never hashes or reformats emails or phone numbers.
- **Vendor names:** never name the ingestion vendor in code or docs; say "ingestion endpoint". Segment library names appear only in `context.library.base` and in notices.
- **Local settings answer:** `SfereSessionTask.resume()` must capture `self` strongly. The base library drops the settings task right after `resume()`, and under XCTest it skips the settings request, so only `testSettingsAnswerArrivesWhenNobodyKeepsTheTask` and the simulator flows cover this path. A dropped answer leaves event processing paused forever.
- **Startup timing:** events queued while the base library starts up go out on the flush interval (30 s by default), not on `flushAt`.
- **Simulator deep links:** `simctl openurl` stops at an "Open in …?" prompt, so the flows open links with `XCUIApplication.open`.
- **Uploads are not gzipped.** Whether the ingress accepts gzip is still unverified.

## Same behaviour as Android

Tests check each behaviour below on both platforms. The two parity tests run the same calls:
- iOS: `WireTests.testParityScenarioAndDeepLinkProperties` (this repo)
- Android: `TransportTest.parityScenarioAndDeepLinkProperties` (`sfere-android-sdk`)

`tools/parity.sh` must report every shared file and every event as "same". When you change what the SDK sends, make the matching change in `sfere-android-sdk` too (matching PRs in both repos), and run `tools/parity.sh` with both repos checked out side by side.

These files are shared and must stay byte-identical in both repos: `fixtures/deeplinks.json`, `fixtures/event-names.json`, `tools/parity.sh`, `tools/parity_diff.py`, `tools/mock_ingest.mjs` and `tools/mock_ingest_ctl.sh`. Change them in both repos in the same round; `tools/parity.sh` fails while they differ.

- **Consent:** `consent` in the config is the initial value only. Consent already stored by `setConsent` wins.
- **Reset:** `reset()` clears the user id, traits, session and click IDs. Consent and opt-out stay.
- **Opt-out:** `setEnabled(false)` deletes events not yet uploaded and is remembered across launches.
- **`deep_link_opened`:** properties are only `url`, `referring_application` and `sfere_dedup_id`.
- **Device id:** no `context.device.id`; the sanitizer removes the IDFV. The privacy manifest declares product interaction and usage data, linked to the user, and no device ID.
- **Dropped keys:** `instanceId`, `referrer`, `__eventOrigin` and `metrics` are removed. So are an empty `category` and empty `properties`.

## Decisions (2026-10-13 to 18)

- **Separate repos (2026-10-18):** iOS and Android are separate repos because apps integrate them differently. The combined repo was deleted.
- **Distribution:** private during beta (private SPM repo), then public (SPM) at 1.0.0.
- **Push tracking:** not in v1; it comes in v1.1.
- **Platform context (Q2, 2026-10-15):** keep everything the base library adds: `app`, `device` (without `id`), `os`, `locale`, `timezone`, `userAgent`, `screen`, `network`.
- **2026-10-15 answers (Q3–Q9 in the next-steps page):** native UI tests (XCUITest); advertising IDs in v1 but off by default (`collectAdvertisingId`); GitHub Actions on every PR; Claude opens a PR for the contract docs in `fanfinity/sfere-sdk`; beta pilot app `sfere-sdk-demo`. (Q3 said "one private repo"; the 2026-10-18 split replaces it.)
- **React Native:** the React Native SDK will wrap this SDK and the Android one.
- **Minimum OS:** iOS 15.

## Still open

- **Spike B (Q1, open):** send real events to staging `/v1/batch/b` with a browser key, and check gzip support. This needs a staging host and key.
- **`debug` option:** the README and `SfereConfiguration` say debug mode prints every payload, but the SDK prints none. Decide whether to add payload logging (on both platforms) or fix the docs.
- **Simulator context:** `context.network` is all false and `device.model` is `arm64` on the simulator; check both on a real device before deciding anything from them.
- **Next round:** advertising IDs, CI.
