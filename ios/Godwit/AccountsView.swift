import SwiftUI

struct AccountsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove: Account?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.accounts) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.email).font(.body)
                            HStack(spacing: 6) {
                                if model.syncing.contains(a.id) { ProgressView().controlSize(.mini); Text("Syncing") }
                                else if let e = model.syncErrors[a.id] { Text(e).foregroundStyle(.orange) }
                                else { Text(status(a)) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { confirmRemove = a }
                        }
                    }
                } footer: {
                    Text("Godwit for iOS is read-only for now: you can read and search mail, but not send, move, delete or mark it.")
                }
                Section {
                    NavigationLink { AddAccountView(isFirst: false) } label: { Label("Add account", systemImage: "plus") }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove \(confirmRemove?.email ?? "")?", isPresented: .init(
                get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
            ), titleVisibility: .visible) {
                Button("Remove from this iPhone", role: .destructive) {
                    guard let a = confirmRemove else { return }
                    Task {
                        do { try await model.removeAccount(a.id) } catch { self.error = error.localizedDescription }
                    }
                }
            } message: {
                Text("Its mail is deleted from this iPhone. Nothing changes on the server.")
            }
        }
    }

    private func status(_ a: Account) -> String {
        switch a.status ?? "" {
        case "", "ok": return a.folders.map { "\($0) folders" } ?? "Ready"
        case "reauth_required": return "Sign-in needed"
        default: return a.statusDetail ?? a.status ?? ""
        }
    }
}
