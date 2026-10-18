# Sfere iOS SDK

Collect first-party fan events in your iOS app and send them to Sfere. It sends the same payload and event names as the Sfere browser and server SDKs, so the same reports and ad-platform destinations work for web and app.

- Swift Package: `SfereAnalytics`
- Requires iOS 15+, Swift 5.9+
- Events are queued on disk, sent in batches, and retried after network errors, `5xx` and `429`. The queue survives app restarts.
- Every request goes to the ingestion host you configure. The SDK makes no other network calls.

## Install

> **Not yet published.** No release exists yet: the repository is private and has no release tag yet, so the steps below describe the planned install path for the beta.

In Xcode, choose **File → Add Package Dependencies…**, enter this repository's URL and add the `SfereAnalytics` product to your app target.

Or add it in `Package.swift`:

```swift
.package(url: "https://github.com/fanfinity/sfere-ios-sdk.git", from: "0.1.0"),
// target dependency:
.product(name: "SfereAnalytics", package: "sfere-ios-sdk"),
```

During the beta the repository is private, so Xcode needs a GitHub account with access to it.

## Set up

Call `setup` once, as early as possible in `application(_:didFinishLaunchingWithOptions:)`:

```swift
import SfereAnalytics

let config = SfereConfiguration(
    writeKey: "keyId:secret",             // your Sfere browser key
    host: "https://ingest.example.com"    // your ingestion host: https, no path
)
config.consent = ["analytics": true, "advertising": false]   // optional
Sfere.setup(config)
```

Use the **browser key** Sfere gave you. It is public by design and only allows sending events. Never put a server key in an app.

| Option | Default | What it does |
|---|---|---|
| `flushAt` | 20 | Events per upload |
| `flushInterval` | 30 | Seconds between uploads. The SDK also uploads when the app goes to the background |
| `sessionTimeoutMinutes` | 30 | Inactivity before a new session starts. Bringing the app to the foreground counts as activity |
| `trackLifecycleEvents` | true | Sends `app_installed`, `app_opened`, `app_updated`, `app_backgrounded` |
| `trackDeepLinks` | true | Sends `deep_link_opened` from `openURL` |
| `consent` | not set | Initial consent categories. Consent already stored by `setConsent` wins. |
| `debug` | false | Prints every payload and validation warning to the console |

If the key or host is invalid, the SDK prints an error and stays inactive: calls are ignored and never crash your app.

## Send events

```swift
Sfere.shared.identify(userId: "user_123", traits: ["email": "fan@example.com", "phone": "+966500000000"])
Sfere.shared.screen("Match Center", properties: ["match_id": "42"])
Sfere.shared.track("add_to_cart", properties: [
    "currency": "SAR",
    "value": 89.99,
    "items": [["item_id": "sku_12345", "item_name": "Away Jersey", "price": 89.99, "quantity": 1]],
])
Sfere.shared.reset()   // on logout
```

- Use the GA4 event names and properties from Sfere's events reference (`view_item`, `add_to_cart`, `begin_checkout`, `purchase`, `search`, `login`, …). Custom events are fine too; use snake_case.
- Send email and phone as plain values. The SDK never hashes them; Sfere hashes per destination.
- `identify` traits are carried on every later event until `reset()`.

### Purchases

```swift
Sfere.shared.purchase(SferePurchase(
    transactionId: "order_98765",
    currency: "SAR",
    value: 256.96,
    items: [SfereItem(itemId: "sku_12345", itemName: "Away Jersey", price: 89.99, quantity: 2, itemCategories: ["Apparel"])],
    tax: 16.99,
    shipping: 10,
    dedupId: "order_98765"   // same value your server sends, if it also reports this purchase
))
```

### Events the SDK sends for you

| Event | When |
|---|---|
| `app_installed` | First launch |
| `app_updated` | First launch of a new version (`previous_version`, `previous_build`) |
| `app_opened` | Cold start and return to the foreground (`from_background`) |
| `app_backgrounded` | App goes to the background |
| `session_started` | First event of each session |
| `deep_link_opened` | `openURL` was called (`url`, `referring_application`) |

## Deep links and ad clicks

Pass every link that opens your app to the SDK. Click IDs (`gclid`, `fbclid`, `ttclid`, …) and UTM values in the link are attached to every event for the rest of the session, so ad platforms can match conversions to the click.

```swift
// UIApplicationDelegate
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    Sfere.shared.openURL(url, options: options)
    return true
}

// Universal links
func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if let url = userActivity.webpageURL { Sfere.shared.openURL(url) }
    return true
}

// SwiftUI
.onOpenURL { url in Sfere.shared.openURL(url) }
```

With scenes, call it from `scene(_:openURLContexts:)` and `scene(_:continue:)`, and for links that launch the app, from `scene(_:willConnectTo:options:)`.

## Consent and opt-out

```swift
Sfere.shared.setConsent(["analytics": true, "advertising": true])   // applies from the next event; saved
Sfere.shared.setEnabled(false)   // stops collection and deletes events not yet sent; saved across launches
```

Consent is sent as `context.consent.categoryPreferences` and is left out until you set it.

## Privacy

- The package includes a privacy manifest (`PrivacyInfo.xcprivacy`). It declares product interaction and other usage data, collected for analytics and linked to the user (events carry your `userId` after `identify`), no tracking, and UserDefaults access (reason `CA92.1`). The SDK sends no device identifier: it removes the identifier for vendor that the base library would add. Xcode merges it into your app's privacy report.
- The SDK does not read the advertising identifier (IDFA) and never shows the App Tracking Transparency prompt.

## Testing against a local mock

Debug builds accept an `http://` host, so you can point the SDK at a local mock ingestion server:

```swift
let config = SfereConfiguration(writeKey: "keyId:secret", host: "http://127.0.0.1:4311")
config.debug = true
```

- The iOS Simulator reaches your Mac at `127.0.0.1`. Allow it in your debug build's App Transport Security settings with `NSAllowsLocalNetworking`.
- Release builds reject `http://` hosts and stay inactive.

## Developing this SDK

[`TESTING.md`](TESTING.md) has every test step: the parity check against the Android SDK, the sample app and the simulator flows. From the repository root:

```bash
swift build
swift test      # unit tests, the shared fixtures in fixtures/, and end-to-end payload checks
xcodebuild build -scheme SfereAnalytics -destination 'generic/platform=iOS Simulator'
```
