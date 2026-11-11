import SwiftUI

/// App-password (or plain password) IMAP/SMTP accounts. OAuth, JMAP, EWS and
/// POP3 sign-in come later; the core already has them.
struct AddAccountView: View {
    let isFirst: Bool
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var provider: Provider?
    @State private var detecting = false
    @State private var showServers = false
    @State private var username = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var imapSec = "tls"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var smtpSec = "tls"
    @State private var checking = false
    @State private var steps: [CheckStep] = []
    @State private var error: String?

    private var canConnect: Bool {
        email.contains("@") && !password.isEmpty && !imapHost.isEmpty && !checking && !detecting
    }

    var body: some View {
        Form {
            if isFirst {
                Section {
                    Text("Godwit keeps your mail on this iPhone. Add an account to start.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await detect() } }
                SecureField(passwordLabel, text: $password)
                    .textContentType(.password)
            } footer: {
                if let p = provider, p.id != "other" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name).bold()
                        if needsAppPassword(p) {
                            Text("\(p.name) needs an app password, not your normal one.")
                        }
                        if let help = p.helpURL, let url = URL(string: help) {
                            Link("How to make one", destination: url)
                        }
                    }
                } else if detecting {
                    ProgressView()
                }
            }

            Section {
                DisclosureGroup("Servers", isExpanded: $showServers) {
                    TextField("Username (if not the address)", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    serverRow("IMAP", host: $imapHost, port: $imapPort, security: $imapSec)
                    serverRow("SMTP", host: $smtpHost, port: $smtpPort, security: $smtpSec)
                }
            }

            if !steps.isEmpty {
                Section("Check") {
                    ForEach(steps) { s in
                        HStack(alignment: .top) {
                            Image(systemName: s.skipped ? "minus.circle" : s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(s.skipped ? Color.secondary : s.ok ? Color.green : Color.red)
                            VStack(alignment: .leading) {
                                Text(s.name)
                                if let d = s.detail, !d.isEmpty, !s.ok { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text("Connect"); if checking { Spacer(); ProgressView() } }
                }
                .disabled(!canConnect)
            }
        }
        .navigationTitle("Add account")
        .onChange(of: email) { provider = nil }
        // Look up the servers once typing pauses, not only on Return.
        .task(id: email) {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { await detect() }
        }
    }

    private var passwordLabel: String {
        if let p = provider, needsAppPassword(p) { return "App password" }
        return "Password"
    }

    private func needsAppPassword(_ p: Provider) -> Bool {
        p.entry("imap")?.login == "app_password"
    }

    @ViewBuilder
    private func serverRow(_ label: String, host: Binding<String>, port: Binding<String>, security: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("Host", text: host).textInputAutocapitalization(.never).autocorrectionDisabled()
            HStack {
                TextField("Port", text: port).keyboardType(.numberPad).frame(width: 80)
                Picker("Security", selection: security) {
                    Text("TLS").tag("tls")
                    Text("STARTTLS").tag("starttls")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func detect() async {
        let addr = email.trimmingCharacters(in: .whitespaces)
        guard let at = addr.firstIndex(of: "@"), addr[at...].contains("."), provider == nil else { return }
        detecting = true
        defer { detecting = false }
        // DetectProvider returns [Provider, Source].
        guard let data = try? await Core.raw("DetectProvider", [addr]),
              let pair = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let first = pair.first,
              let pdata = try? JSONSerialization.data(withJSONObject: first),
              let p = try? Core.decoder.decode(Provider.self, from: pdata) else {
            showServers = true
            return
        }
        provider = p
        if let i = p.entry("imap") { imapHost = i.host; imapPort = String(i.port); imapSec = i.security }
        if let s = p.entry("smtp") { smtpHost = s.host; smtpPort = String(s.port); smtpSec = s.security }
        if let u = p.username, !u.isEmpty, username.isEmpty { username = u }
        if p.id == "other" || imapHost.isEmpty { showServers = true }
    }

    private var input: [String: Any] {
        let addr = email.trimmingCharacters(in: .whitespaces)
        var i: [String: Any] = [
            "Email": addr,
            "Username": username.trimmingCharacters(in: .whitespaces).isEmpty ? addr : username.trimmingCharacters(in: .whitespaces),
            "Password": password,
            "Receiving": ["Host": imapHost.trimmingCharacters(in: .whitespaces), "Port": Int(imapPort) ?? 993, "Security": imapSec],
            "Sending": ["Host": smtpHost.trimmingCharacters(in: .whitespaces), "Port": Int(smtpPort) ?? 465, "Security": smtpSec],
        ]
        if let p = provider { i["Provider"] = p.id }
        return i
    }

    private func connect() async {
        await detect()
        guard canConnect else { showServers = true; return }
        checking = true
        error = nil
        steps = []
        defer { checking = false }
        var params = input
        do {
            let report = try await Core.call("CheckAccount", [params], as: CheckReport.self)
            steps = report.steps ?? []
            let failed = steps.filter { !$0.ok && !$0.skipped }
            // A read-only app can live without working SMTP: add it receive-only.
            if !failed.isEmpty {
                // Core re-checks this (CheckReport.OnlySMTPFailed) before it lets ReceiveOnly through.
                guard failed.allSatisfy({ $0.name == "smtp" }) else { return }
                params["ReceiveOnly"] = true
            }
            let account = try await Core.call("AddAccount", [params], as: Account.self)
            await model.refreshAccounts()
            Task { _ = try? await Core.raw("SyncNow", [account.id]) }
            if !isFirst { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
