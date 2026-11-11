import SwiftUI

struct ThreadView: View {
    let threadID: Int64
    @State private var thread: MailThread?
    @State private var error: String?
    @State private var expanded: Set<Int64> = []

    var body: some View {
        ScrollView {
            if let thread {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                        .font(.title3.weight(.semibold))
                        .padding()
                    ForEach(thread.messages ?? []) { m in
                        Divider()
                        MessageCard(summary: m, isExpanded: expanded.contains(m.id)) {
                            if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("Couldn't open this conversation", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().padding(.top, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let t = try await Core.call("GetThread", [threadID], as: MailThread.self)
            thread = t
            // Open the newest message and any unread ones, the way a reader expects.
            let msgs = t.messages ?? []
            expanded = Set(msgs.filter(\.isUnread).map(\.id))
            if let last = msgs.last { expanded.insert(last.id) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MessageCard: View {
    let summary: MessageSummary
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var message: Message?
    @State private var error: String?
    @State private var bodyHeight: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(summary.from)).font(.subheadline.weight(.semibold))
                        if isExpanded {
                            if let to = summary.to, !to.isEmpty {
                                Text("To " + to.map(displayName).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } else {
                            Text(summary.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let message {
                    if let html = message.html, !html.isEmpty {
                        MessageBodyView(html: html, height: $bodyHeight)
                            .frame(height: bodyHeight)
                    } else {
                        Text(message.text ?? "")
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let blocked = message.remoteImagesBlocked, blocked > 0 {
                        Label("\(blocked) remote image\(blocked == 1 ? "" : "s") blocked", systemImage: "eye.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    let files = (message.attachments ?? []).filter { $0.inline != true }
                    if !files.isEmpty {
                        ForEach(files, id: \.id) { a in
                            Label(a.filename ?? "attachment", systemImage: "paperclip").font(.caption)
                        }
                    }
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .task(id: isExpanded) {
            guard isExpanded, message == nil else { return }
            do { message = try await Core.call("GetMessage", [summary.id, false], as: Message.self) }
            catch { self.error = error.localizedDescription }
        }
    }
}
