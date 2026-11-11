import SwiftUI

@main
struct GodwitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .starting:
            ProgressView("Starting Godwit")
        case .failed(let message):
            ContentUnavailableView("Godwit couldn't start", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            if model.accounts.isEmpty {
                NavigationStack { AddAccountView(isFirst: true) }
            } else {
                MainView()
            }
        }
    }
}

func debugArg(_ flag: String) -> String? {
    #if DEBUG
    let a = ProcessInfo.processInfo.arguments
    if let i = a.firstIndex(of: flag), a.count > i + 1 { return a[i + 1] }
    #endif
    return nil
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: ThreadSummary.ID?
    @State private var showSearch = false
    @State private var showAccounts = false

    var body: some View {
        NavigationSplitView {
            InboxView(selected: $selected, showSearch: $showSearch, showAccounts: $showAccounts)
        } detail: {
            if let id = selected {
                ThreadView(threadID: id).id(id)
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "envelope")
            }
        }
        .sheet(isPresented: $showSearch) { SearchView(initialQuery: debugArg("-search") ?? "") }
        .sheet(isPresented: $showAccounts) { AccountsView() }
        #if DEBUG
        // Screenshot hooks: -openThread <index>, -search <text>, -accounts.
        .onChange(of: model.threads.count) {
            if selected == nil, let i = debugArg("-openThread").flatMap(Int.init), model.threads.indices.contains(i) {
                selected = model.threads[i].id
            }
        }
        .task {
            if debugArg("-search") != nil { showSearch = true }
            if ProcessInfo.processInfo.arguments.contains("-accounts") { showAccounts = true }
        }
        #endif
    }
}
