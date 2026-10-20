import SfereAnalytics
import SwiftUI
import UIKit

@main
struct SfereExampleApp: App {
    @UIApplicationDelegateAdaptor(SampleAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Deep links: xcrun simctl openurl booted "sfereexample://match/42?gclid=abc"
                .onOpenURL { url in Sfere.shared.openURL(url) }
        }
    }
}

/// Sets the SDK up in `application(_:didFinishLaunchingWithOptions:)`, as the README says.
final class SampleAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let settings = SampleSettings()
        let configuration = SfereConfiguration(writeKey: settings.writeKey, host: settings.host)
        configuration.flushAt = 1
        configuration.sessionTimeoutMinutes = settings.sessionTimeoutMinutes
        configuration.debug = true
        Sfere.setup(configuration)
        return true
    }
}
