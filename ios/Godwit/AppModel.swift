import Foundation
import SwiftUI

enum Mailbox: Hashable {
    case inbox, starred
    var unified: String { self == .inbox ? "inbox" : "starred" }
    var title: String { self == .inbox ? "Inbox" : "Starred" }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case starting, ready, failed(String) }

    @Published var phase: Phase = .starting
    @Published var accounts: [Account] = []
    @Published var threads: [ThreadSummary] = []
    @Published var mailbox: Mailbox = .inbox
    @Published var accountFilter: Int64? = nil
    @Published var syncing: Set<Int64> = []
    @Published var syncErrors: [Int64: String] = [:]
    @Published var listError: String?

    private var nextCursor = ""
    private var loadingMore = false
    private var reloadTask: Task<Void, Never>?
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await Core.start { [weak self] e in Task { @MainActor in self?.handle(e) } }
            await refreshAccounts()
            #if DEBUG
            await addTestAccountIfAsked()
            #endif
            phase = .ready
            await reload()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refreshAccounts() async {
        do { accounts = try await Core.call("ListAccounts", as: [Account]?.self) ?? [] }
        catch { listError = error.localizedDescription }
    }

    private var view: [String: Any] {
        var v: [String: Any] = ["Unified": mailbox.unified]
        if let a = accountFilter { v["AccountID"] = a }
        return v
    }

    func reload() async {
        do {
            let page = try await Core.call("ListThreads", [view, "", 50], as: ThreadPage.self)
            threads = page.items ?? []
            nextCursor = page.nextCursor ?? ""
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(after t: ThreadSummary) async {
        guard t.id == threads.last?.id, !nextCursor.isEmpty, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await Core.call("ListThreads", [view, nextCursor, 50], as: ThreadPage.self) {
            let seen = Set(threads.map(\.id))
            threads += (page.items ?? []).filter { !seen.contains($0.id) }
            nextCursor = page.nextCursor ?? ""
        }
    }

    /// Pull to refresh: sync every account (or the filtered one), then reload.
    func syncAll() async {
        let ids = accountFilter.map { [$0] } ?? accounts.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = try? await Core.raw("SyncNow", [id]) }
            }
        }
        await reload()
    }

    /// Core events are hints: coalesce them and re-read.
    private func handle(_ e: CoreEvent) {
        switch e.type {
        case "sync.started":
            if let a = e.accountID { syncing.insert(a) }
        case "sync.finished":
            if let a = e.accountID { syncing.remove(a); syncErrors[a] = nil }
            scheduleReload()
        case "sync.failed":
            if let a = e.accountID { syncing.remove(a); syncErrors[a] = e.error ?? e.kind ?? "sync failed" }
        case "messages.changed", "message.received":
            scheduleReload()
        default:
            break
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshAccounts()
            await self?.reload()
        }
    }

    #if DEBUG
    /// Debug builds only: `-testAccount host port email password` adds that
    /// account on first launch, for a local test IMAPS server.
    private func addTestAccountIfAsked() async {
        let a = ProcessInfo.processInfo.arguments
        guard accounts.isEmpty, let i = a.firstIndex(of: "-testAccount"), a.count > i + 4 else { return }
        let host = a[i + 1], port = Int(a[i + 2]) ?? 9993
        let input: [String: Any] = [
            "Email": a[i + 3], "Username": a[i + 3], "Password": a[i + 4],
            "Receiving": ["Host": host, "Port": port, "Security": "tls"],
            "Sending": ["Host": host, "Port": 9465, "Security": "tls"],
        ]
        do {
            let acc = try await Core.call("AddAccount", [input], as: Account.self)
            await refreshAccounts()
            Task { _ = try? await Core.raw("SyncNow", [acc.id]) }
        } catch {
            listError = "test account: \(error.localizedDescription)"
        }
    }
    #endif

    func removeAccount(_ id: Int64) async throws {
        try await Core.raw("RemoveAccount", [id])
        if accountFilter == id { accountFilter = nil }
        await refreshAccounts()
        await reload()
    }
}
