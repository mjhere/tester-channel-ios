import SwiftUI
import TesterChannel

/// A host app with the panel in it, talking to `FakeService` instead of a server.
///
/// Two tabs because that is how a real host tends to carry it, and because it is
/// the only way to see the part of the client that runs while the panel is not
/// on screen: the idle poll and the badge.
@main
struct TesterChannelDemoApp: App {
    @StateObject private var demo = DemoModel()

    var body: some Scene {
        WindowGroup {
            RootView(client: demo.client)
                .environmentObject(demo)
                .task { await demo.start() }
        }
    }
}

@MainActor
final class DemoModel: ObservableObject {
    let client: TesterChannelClient

    @Published var offline = false {
        didSet { FakeService.shared.offline = offline }
    }
    @Published var removed = false {
        didSet { FakeService.shared.removed = removed }
    }
    @Published var locale = "en" {
        didSet { client.setLocale(locale) }
    }
    @Published var startError: String?

    static let locales = ["en", "cs", "sk", "de", "art-x-huttese"]

    init() {
        // AsyncImage loads attachments through URLSession.shared, which only a
        // registered protocol reaches. The SDK's own session gets it explicitly.
        URLProtocol.registerClass(FakeURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeURLProtocol.self]
        client = TesterChannelClient(
            publishableKey: "pk_demo", baseUrl: FakeService.baseUrl,
            urlSession: URLSession(configuration: config))
        // Quicker than the SDK's defaults, so something the Director sends shows
        // up while you are still looking for it.
        client.pollInterval = .seconds(2)
        client.idlePollInterval = .seconds(5)
    }

    func start() async {
        startError = nil
        do {
            // The fake does not check the hash. A real host gets it from its own
            // backend, never from a secret shipped in the app.
            try await client.identify(
                userId: "demo-tester", userHash: "unchecked",
                traits: ["name": "Alex"], build: "demo", locale: locale)
        } catch {
            startError = error.localizedDescription
        }
    }

    func resetDemo() async {
        client.reset()
        FakeService.shared.reset()
        offline = false
        removed = false
        await start()
    }

    /// Five messages two seconds apart: time to scroll up and watch them not
    /// pull you back down.
    func burst() {
        Task {
            for _ in 0..<5 {
                FakeService.shared.operatorSends()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var client: TesterChannelClient
    @EnvironmentObject private var demo: DemoModel
    @State private var tab = 1

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HostHome(client: client, openFeedback: { tab = 1 })
                    .navigationTitle("Your app")
                    .toolbar { ToolbarItem(placement: .primaryAction) { DirectorMenu() } }
            }
            .tabItem { Label("App", systemImage: "house") }
            .tag(0)

            NavigationStack {
                feedback
                    .navigationTitle("Feedback")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .primaryAction) { DirectorMenu() } }
            }
            .tabItem { Label("Feedback", systemImage: "bubble.left.and.bubble.right") }
            .badge(client.unreadCount)
            .tag(1)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if client.app != nil {
            TesterChannelView(client: client)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .background(Color(uiColor: .systemGroupedBackground))
        } else if let error = demo.startError {
            VStack(spacing: 12) {
                Text("Could not start: \(error)")
                Button("Try again") { Task { await demo.start() } }
            }
            .padding()
        } else {
            ProgressView()
        }
    }
}

/// Stands in for the host app's own screens.
struct HostHome: View {
    @ObservedObject var client: TesterChannelClient
    @EnvironmentObject private var demo: DemoModel
    let openFeedback: () -> Void

    var body: some View {
        List {
            Section {
                Text("This tab is the host app. While you are here the panel is hidden, so the client only polls the unread count, every 5 seconds in this demo.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Tester Channel") {
                LabeledContent("Unread", value: "\(client.unreadCount)")
                LabeledContent("Tester", value: client.displayName ?? "not named yet")
                LabeledContent("Network", value: demo.offline ? "offline" : "online")
                Button("Open feedback", action: openFeedback)
            }
        }
    }
}

/// The operator's side, and the tester's circumstances, from a menu.
struct DirectorMenu: View {
    @EnvironmentObject private var demo: DemoModel

    var body: some View {
        Menu {
            Section("Operator sends") {
                Button("A message") { FakeService.shared.operatorSends() }
                Button("5 messages, 2 s apart") { demo.burst() }
                Button("A poll") { FakeService.shared.operatorSendsPoll(multiSelect: false) }
                Button("A multi-select poll") { FakeService.shared.operatorSendsPoll(multiSelect: true) }
                Button("A test request") { FakeService.shared.operatorSendsTestRequest() }
                Button("A card this build doesn't know") { FakeService.shared.operatorSendsUnknownCard() }
                Button("A system notice") { FakeService.shared.systemNotice() }
            }
            Section("Tester") {
                Toggle("Offline", isOn: $demo.offline)
                Toggle("Removed (on next send)", isOn: $demo.removed)
                Button("Ask for their name again") { FakeService.shared.forgetName() }
                Picker("Language", selection: $demo.locale) {
                    ForEach(DemoModel.locales, id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                Button("Reset demo", role: .destructive) {
                    Task { await demo.resetDemo() }
                }
            }
        } label: {
            Label("Director", systemImage: "theatermasks")
        }
    }
}
