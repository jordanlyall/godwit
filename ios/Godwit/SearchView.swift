import SwiftUI

struct SearchView: View {
    var initialQuery = ""
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MessageSummary] = []
    @State private var searched = false
    @State private var error: String?
    @State private var elapsed: Int?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(results) { m in
                    NavigationLink(value: m.threadID) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(displayName(m.from)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(shortDate(m.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(m.subject.isEmpty ? "(no subject)" : m.subject).font(.subheadline).lineLimit(1)
                            Text(m.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if searched && results.isEmpty && error == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationDestination(for: Int64.self) { ThreadView(threadID: $0) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all mail")
            .onSubmit(of: .search) { Task { await run() } }
            .navigationTitle(elapsed.map { "\(results.count) results · \($0) ms" } ?? "Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                guard !initialQuery.isEmpty, query.isEmpty else { return }
                query = initialQuery
                await run()
            }
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let t0 = Date()
        do {
            results = try await Core.call("SearchWith", [["Text": q], 100], as: [MessageSummary]?.self) ?? []
            error = nil
        } catch {
            results = []
            self.error = error.localizedDescription
        }
        elapsed = Int(Date().timeIntervalSince(t0) * 1000)
        searched = true
    }
}
