// GodwitSpike — throwaway SwiftUI shell for the go/no-go spike.
// Names checked against Godwit.xcframework/ios-arm64/Godwit.framework/Headers/Mobile.objc.h:
// the module is Godwit; MobileStart/Call/Subscribe/Stop are C functions that
// take an NSError** (no Swift throws); MobileHost's BOOL methods import as
// throwing, but secretGet (non-null NSString return) keeps its NSErrorPointer.
// No design. No error handling beyond logging. This is instrumentation.

import SwiftUI
import Godwit
import os

private let spikeLog = Logger(subsystem: "email.godwit.spike", category: "core")

// Metrics go to Documents/spike-metrics.txt so the Mac can pull them with
// `devicectl device copy from` (os_log redacts values on a device).
private let metricsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("spike-metrics.txt")
func metric(_ line: String) {
    let l = "\(Date().timeIntervalSince1970) footprintMB=\(footprintMB()) peakMB=\(footprintMB(peak: true)) \(line)\n"
    if let h = try? FileHandle(forWritingTo: metricsURL) { h.seekToEndOfFile(); h.write(Data(l.utf8)); try? h.close() }
    else { try? Data(l.utf8).write(to: metricsURL) }
}
// phys_footprint is what Xcode's memory gauge and jetsam use.
func footprintMB(peak: Bool = false) -> String {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? String(format: "%.1f", Double(peak ? Int64(info.ledger_phys_footprint_peak) : Int64(info.phys_footprint)) / 1_048_576) : "?"
}
// Process start time, for launch→first-ListThreads (true cold start, not just from start()).
func processStart() -> Date {
    var kp = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &kp, &size, nil, 0)
    let tv = kp.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
}

// In-memory keychain for the spike. The real shell wraps SecItem here.
// An empty string from secretGet means "not found" (see mobile/bridge.go).
final class SpikeHost: NSObject, MobileHostProtocol {
    private var secrets: [String: String] = [:]
    private let lock = NSLock()
    private func key(_ s: String?, _ a: String?) -> String { "\(s ?? "")\u{0}\(a ?? "")" }
    func secretGet(_ service: String?, account: String?, error: NSErrorPointer) -> String {
        lock.lock(); defer { lock.unlock() }
        return secrets[key(service, account)] ?? ""
    }
    func secretSet(_ service: String?, account: String?, value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[key(service, account)] = value ?? ""
    }
    func secretDelete(_ service: String?, account: String?) throws {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: key(service, account))
    }
    func log(_ line: String?) { spikeLog.info("\(line ?? "")") }
}

final class SpikeSink: NSObject, MobileEventSinkProtocol {
    var onEvent: (String) -> Void = { _ in }
    func onEvent(_ eventJSON: String?) { if let e = eventJSON { onEvent(e) } }
}

@MainActor
final class Spike: ObservableObject {
    @Published var status = "idle"
    @Published var threads: [String] = []   // raw JSON lines; the spike doesn't model them
    @Published var events: [String] = []
    @Published var host = "imap.fastmail.com"
    @Published var port = "993"
    @Published var user = ""
    @Published var password = ""
    @Published var query = ""
    @Published var smtpHost = "smtp.fastmail.com"
    var smtpPort = 465
    private var accountID: Int64 = 0
    private var syncStart = Date()

    private let hostImpl = SpikeHost()
    private let sink = SpikeSink()
    private var launch = Date()

    func start() {
        launch = Date()
        #if targetEnvironment(simulator)
        // The simulator's container sits under ~/Library/Developer/CoreSimulator/…:
        // its Documents path alone is ~175 bytes, past sun_path. Simulator apps
        // can write the host's /tmp, so use a short directory there. Device: Documents.
        let docs = "/tmp/godwit-spike"
        try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        #endif
        spikeLog.info("dataDir=\(docs) len=\(docs.utf8.count) socket=\(docs.utf8.count + 12)")  // + "/godwit.sock"
        // mobile.Start finds the embedded MygoSQLite.framework itself (Go reads the
        // environment at load, so a setenv here would come too late).
        var err: NSError?
        guard MobileStart(docs, Locale.current.identifier, "spike", hostImpl, &err) else {
            status = "start failed: \(err?.localizedDescription ?? "unknown")"
            spikeLog.error("start failed: \(String(describing: err))")
            return
        }
        status = "started in \(ms(since: launch)) ms"
        spikeLog.info("\(self.status)")
        metric("start ms=\(ms(since: launch)) sinceProcess=\(ms(since: processStart())) dataDir=\(docs) socketLen=\(docs.utf8.count + 12)")
        sink.onEvent = { [weak self] e in Task { @MainActor in self?.events.insert(e.prefix(200).description, at: 0) } }
        if !MobileSubscribe(sink, &err) { status = "subscribe failed: \(err?.localizedDescription ?? "unknown")" }
    }

    // core.AccountInput (core/types.go). CheckAccount and AddAccount take it as
    // their one param; SMTP is required by validate() even for a read-only spike.
    func addAccount() {
        let input: [String: Any] = [
            "Email": user, "Username": user, "Password": password,
            "IMAPHost": host, "IMAPPort": Int(port) ?? 993, "IMAPSecurity": "tls",
            "SMTPHost": smtpHost, "SMTPPort": smtpPort, "SMTPSecurity": "tls",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: [input]),
              let params = String(data: data, encoding: .utf8) else { return }
        syncStart = Date()
        call("CheckAccount", params) { [weak self] json in
            metric("checkAccount ms=\(self?.ms(since: self?.syncStart ?? Date()) ?? 0) \(json.prefix(600))")
            self?.call("AddAccount", params) { json in
                guard let self,
                      let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let id = (obj["ID"] as? NSNumber)?.int64Value else { self?.status = "AddAccount: no ID in \(json.prefix(120))"; return }
                self.accountID = id
                self.status = "account \(id) added; syncing"
                spikeLog.info("account \(id) added at \(self.ms(since: self.syncStart)) ms")
                metric("addAccount ms=\(self.ms(since: self.syncStart))")
                self.call("SyncNow", "[\(id)]") { _ in
                    metric("syncNow returned ms=\(self.ms(since: self.syncStart))")
                    self.listThreads()
                    self.query = "launch"; self.search()
                    Task { try? await Task.sleep(for: .seconds(15)); metric("idleAfterSync15s") }
                }
            }
        }
    }

    // ListThreads(View, cursor, limit); View{Unified:"inbox"} is the unified inbox.
    func listThreads() {
        let t0 = Date()
        call("ListThreads", #"[{"Unified":"inbox"}, "", 50]"#) { [weak self] json in
            guard let self else { return }
            self.threads = [String(json.prefix(4000))]
            self.status = "ListThreads \(self.ms(since: t0)) ms · \(self.ms(since: self.launch)) ms since launch"
            spikeLog.info("\(self.status)")
            metric("listThreads ms=\(self.ms(since: t0)) sinceProcess=\(self.ms(since: processStart())) bytes=\(json.utf8.count)")
        }
    }

    // Search(accountID, query, limit).
    func search() {
        let t0 = Date()
        guard let q = try? JSONSerialization.data(withJSONObject: [query], options: .fragmentsAllowed),
              let qs = String(data: q, encoding: .utf8) else { return }
        call("Search", "[\(accountID), \(qs.dropFirst().dropLast()), 50]") { [weak self] json in
            self?.threads = [json]
            self?.status = "Search \(self?.ms(since: t0) ?? 0) ms"
            metric("search ms=\(self?.ms(since: t0) ?? 0) bytes=\(json.utf8.count)")
        }
    }

    private func call(_ method: String, _ params: String, done: @escaping (String) -> Void) {
        Task.detached {
            var err: NSError?
            let res = MobileCall(method, params, &err)
            let failure = err
            await MainActor.run {
                if let err = failure { self.status = "\(method): \(err.localizedDescription)"; spikeLog.error("\(method) \(err)") }
                else { done(res) }
            }
        }
    }

    private func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
}

struct ContentView: View {
    @StateObject private var spike = Spike()
    var body: some View {
        NavigationStack {
            List {
                Section(spike.status) {
                    Button("Start core") { spike.start() }
                    TextField("IMAP host", text: $spike.host)
                    TextField("Port", text: $spike.port)
                    TextField("SMTP host", text: $spike.smtpHost)
                    TextField("Email", text: $spike.user).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    SecureField("App password", text: $spike.password)
                    Button("Check + add account + sync") { spike.addAccount() }
                    Button("List threads") { spike.listThreads() }
                    HStack { TextField("Search", text: $spike.query); Button("Go") { spike.search() } }
                }
                Section("Threads (raw)") { ForEach(spike.threads.prefix(50), id: \.self) { Text($0).font(.caption.monospaced()).lineLimit(40) } }
                Section("Events") { ForEach(spike.events.prefix(30), id: \.self) { Text($0).font(.caption2.monospaced()).lineLimit(2) } }
            }
            .navigationTitle("Godwit spike")
            // `-autostart` (launch argument): Start, then ListThreads, with no taps — the cold-start measurement.
            .task {
                // `-autosync host imapPort smtpHost smtpPort user pass`: Start, add the account,
                // sync, then ListThreads + Search, all logged to spike-metrics.txt. Test servers only.
                let a = ProcessInfo.processInfo.arguments
                // `-wipe`: empty Documents first (a clean initial sync without reinstalling,
                // which would also reset the Local Network permission).
                if a.contains("-wipe"), let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                   let items = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
                    for u in items { try? FileManager.default.removeItem(at: u) }
                }
                if let i = a.firstIndex(of: "-autosync"), a.count > i + 6 {
                    spike.host = a[i+1]; spike.port = a[i+2]; spike.smtpHost = a[i+3]
                    spike.smtpPort = Int(a[i+4]) ?? 465; spike.user = a[i+5]; spike.password = a[i+6]
                    spike.start()
                    metric("autosync begin")
                    spike.addAccount()
                } else if ProcessInfo.processInfo.arguments.contains("-autostart") {
                    spike.start()
                    spike.listThreads()
                    try? await Task.sleep(for: .seconds(10))
                    metric("idle10s")
                }
            }
        }
    }
}
