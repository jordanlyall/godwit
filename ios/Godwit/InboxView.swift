import SwiftUI

struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selected: ThreadSummary.ID?
    @Binding var showSearch: Bool
    @Binding var showAccounts: Bool

    private var title: String {
        if let a = model.accountFilter, let acc = model.accounts.first(where: { $0.id == a }) {
            return "\(model.mailbox.title) · \(acc.email)"
        }
        return model.mailbox.title
    }

    var body: some View {
        List(selection: $selected) {
            if let err = model.listError {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            ForEach(Array(model.syncErrors.keys), id: \.self) { id in
                let email = model.accounts.first { $0.id == id }?.email ?? "Account \(id)"
                Label("\(email): \(model.syncErrors[id] ?? "")", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange).font(.footnote)
            }
            ForEach(model.threads) { t in
                ThreadRow(thread: t)
                    .tag(t.id)
                    .task { await model.loadMoreIfNeeded(after: t) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.threads.isEmpty && model.listError == nil {
                if model.syncing.isEmpty {
                    ContentUnavailableView("No mail", systemImage: "tray", description: Text("Pull down to sync."))
                } else {
                    ProgressView("Syncing")
                }
            }
        }
        .refreshable { await model.syncAll() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Mailbox", selection: $model.mailbox) {
                        Label("Inbox", systemImage: "tray").tag(Mailbox.inbox)
                        Label("Starred", systemImage: "star").tag(Mailbox.starred)
                    }
                    if model.accounts.count > 1 {
                        Picker("Account", selection: $model.accountFilter) {
                            Text("All accounts").tag(Int64?.none)
                            ForEach(model.accounts) { a in Text(a.email).tag(Int64?.some(a.id)) }
                        }
                    }
                    Divider()
                    Button { showAccounts = true } label: { Label("Accounts", systemImage: "person.crop.circle") }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !model.syncing.isEmpty { ProgressView() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .onChange(of: model.mailbox) { Task { await model.reload() } }
        .onChange(of: model.accountFilter) { Task { await model.reload() } }
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.unread > 0 ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayName(thread.from))
                        .font(.subheadline.weight(thread.unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.count > 1 {
                        Text("\(thread.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if thread.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    if thread.flagged > 0 { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    Text(shortDate(thread.lastDate)).font(.caption).foregroundStyle(.secondary)
                }
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(thread.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if cal.isDate(d, equalTo: .now, toGranularity: .year) { return d.formatted(.dateTime.month(.abbreviated).day()) }
    return d.formatted(date: .numeric, time: .omitted)
}
