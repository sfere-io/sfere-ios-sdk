import SfereAnalytics
import SwiftUI

/// One screen: settings, consent and opt-out, a button per v1 event, and the requests the mock
/// ingestion server received. Mirrors the Android sample app's MainActivity (sfere-android-sdk, sample/).
struct ContentView: View {
    private let settings = SampleSettings()

    @State private var host = SampleSettings().host
    @State private var writeKey = SampleSettings().writeKey
    @State private var sessionTimeout = String(SampleSettings().sessionTimeoutMinutes)
    @State private var settingsMessage = ""
    @State private var analyticsConsent = false
    @State private var advertisingConsent = false
    @State private var collectionEnabled = Sfere.shared.isActive
    @State private var anonymousId = Sfere.shared.anonymousId ?? "–"
    @State private var receivedText = "Press Refresh to list what the mock received."

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Status")) {
                    LabeledRow(label: "Host", value: settings.host)
                    LabeledRow(label: "Active", value: collectionEnabled ? "yes" : "no")
                    LabeledRow(label: "Anonymous id", value: anonymousId)
                }

                Section(header: Text("Settings (applied on the next launch)")) {
                    TextField("Host", text: $host).keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    TextField("Write key", text: $writeKey).autocapitalization(.none).disableAutocorrection(true)
                    TextField("Session timeout (minutes)", text: $sessionTimeout).keyboardType(.numberPad)
                    Button("Save settings") {
                        settings.host = host
                        settings.writeKey = writeKey
                        settings.sessionTimeoutMinutes = Int(sessionTimeout) ?? SampleSettings.defaultSessionTimeoutMinutes
                        settingsMessage = "Saved. Quit the app from the app switcher and open it again to apply."
                    }
                    if !settingsMessage.isEmpty { Text(settingsMessage).font(.footnote) }
                }

                Section(header: Text("Consent and opt-out")) {
                    Toggle("Consent: analytics", isOn: $analyticsConsent)
                        .onChange(of: analyticsConsent) { _ in applyConsent() }
                    Toggle("Consent: advertising", isOn: $advertisingConsent)
                        .onChange(of: advertisingConsent) { _ in applyConsent() }
                    Toggle("Collection enabled (off = opt-out)", isOn: $collectionEnabled)
                        .onChange(of: collectionEnabled) { enabled in Sfere.shared.setEnabled(enabled) }
                }

                Section(header: Text("Identity and screens")) {
                    eventButton("identify sample_user_1") {
                        Sfere.shared.identify(
                            userId: "sample_user_1",
                            traits: ["email": "fan@example.com", "phone": "+966500000000", "favorite_team": "home"])
                    }
                    eventButton("screen: Match Center") { Sfere.shared.screen("Match Center", properties: ["match_id": "42"]) }
                    eventButton("Open test deep link") { Sfere.shared.openURL(SampleEvents.testDeepLink) }
                    eventButton("reset (logout)") { Sfere.shared.reset() }
                }

                Section(header: Text("Commerce and custom events")) {
                    eventButton("purchase") { Sfere.shared.purchase(SampleEvents.purchase()) }
                    ForEach(SampleEvents.trackEvents, id: \.name) { event in
                        eventButton(event.name) { Sfere.shared.track(event.name, properties: event.properties) }
                    }
                    eventButton("send 200 queue_test_event") {
                        for index in 1...SampleEvents.queueTestCount {
                            Sfere.shared.track("queue_test_event", properties: ["index": index])
                        }
                    }
                    eventButton("flush now") { Sfere.shared.flush() }
                }

                Section(header: Text("Received by the mock")) {
                    Button("Refresh") { Task { await loadReceivedRequests() } }
                    Button("Clear the mock") { Task { await resetMock() } }
                    Text(receivedText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .navigationTitle("Sfere Sample")
        }
        .navigationViewStyle(.stack)
    }

    private func eventButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            action()
            anonymousId = Sfere.shared.anonymousId ?? "–"
        }
    }

    private func applyConsent() {
        Sfere.shared.setConsent(["analytics": analyticsConsent, "advertising": advertisingConsent])
    }

    private func mockURL(_ path: String) -> URL? {
        URL(string: settings.host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    @MainActor
    private func loadReceivedRequests() async {
        guard let url = mockURL("/__events") else { return }
        receivedText = "Loading…"
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let requests = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            var lines = ["\(requests.count) request(s)"]
            for request in requests.reversed() {
                let status = (request["injectedStatus"] as? Int).map { " → \($0)" } ?? ""
                lines.append("\(request["method"] as? String ?? "") \(request["path"] as? String ?? "")\(status)")
                let batch = ((request["body"] as? [String: Any])?["batch"] as? [[String: Any]]) ?? []
                for event in batch {
                    let label = (event["event"] as? String) ?? (event["name"] as? String) ?? ""
                    lines.append("  \(event["type"] as? String ?? "") \(label)")
                }
            }
            receivedText = lines.joined(separator: "\n")
        } catch {
            receivedText = "Could not reach \(url): \(error.localizedDescription)\nStart the mock with tools/mock_ingest_ctl.sh start."
        }
    }

    @MainActor
    private func resetMock() async {
        guard let url = mockURL("/__reset") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            _ = try await URLSession.shared.data(for: request)
            receivedText = "Cleared."
        } catch {
            receivedText = "Could not reach \(url): \(error.localizedDescription)"
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).font(.footnote).lineLimit(1).truncationMode(.middle)
        }
    }
}
