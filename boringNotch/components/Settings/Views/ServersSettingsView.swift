//
//  ServersSettingsView.swift
//  boringNotch
//
//  Settings for the Servers tab: the switch and the Beszel hub's account.
//

import AgentHUDCore
import Defaults
import SwiftUI

struct ServersSettingsView: View {
    @Default(.serversTabEnabled) private var enabled
    @Default(.serversHubURL) private var hubURL
    @Default(.serversUser) private var user
    @State private var password = ""
    @State private var status: (ok: Bool, text: String)?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("显示 Servers 标签", "Show the Servers tab"), isOn: $enabled)
                Defaults.Toggle(key: .serversStayOnTab) {
                    Text(L10n.text("收起后停留在 Servers 页", "Stay on Servers after the notch closes"))
                }
                .disabled(!enabled)
            } footer: {
                Text(L10n.text("在刘海展开后的标签栏里显示 Beszel 监控的服务器。只在这个标签页打开时读取，每 20 秒一次。",
                               "Shows the servers your Beszel hub watches in their own tab. It reads only while the tab is open, every 20 seconds."))
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(L10n.text("地址", "Address"), text: $hubURL)
                TextField(L10n.text("邮箱", "E-mail"), text: $user)
                SecureField(L10n.text("密码", "Password"), text: $password)
                HStack {
                    Button(L10n.text("保存", "Save")) { save() }
                    Button(L10n.text("测试连接", "Test connection")) { Task { await test() } }
                        .disabled(testing || user.isEmpty || password.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if let status {
                        Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(status.ok ? .green : .red)
                            .lineLimit(2)
                    }
                }
            } header: {
                Text("Beszel")
            } footer: {
                Text(L10n.text("密码保存在本机钥匙串里。建议在 Beszel 里给刘海单独建一个只读账号。",
                               "The password is kept in this Mac's keychain. A read-only Beszel account is enough."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Servers")
        .onAppear { password = ServerCredentialStore.password(for: user) ?? "" }
        .onChange(of: enabled) { _, on in
            if !on, BoringViewCoordinator.shared.currentView == .servers {
                BoringViewCoordinator.shared.currentView = .home
            }
        }
    }

    private func save() {
        let saved = ServerCredentialStore.setPassword(password, for: user.trimmingCharacters(in: .whitespaces))
        status = saved ? (true, L10n.text("已保存", "Saved")) : (false, L10n.text("保存失败", "Could not save"))
        ServerMonitor.shared.restart()
    }

    /// Signs in and lists the servers once with what is typed, without saving it.
    private func test() async {
        testing = true
        defer { testing = false }
        guard let base = URL(string: hubURL.trimmingCharacters(in: .whitespacesAndNewlines)), base.scheme?.hasPrefix("http") == true else {
            status = (false, BeszelError.badAddress.localizedDescription)
            return
        }
        let typed = password
        let client = BeszelClient(base: base, user: user.trimmingCharacters(in: .whitespaces)) { typed }
        do {
            let servers = try await client.servers()
            status = (true, L10n.text("连接成功，\(servers.count) 台服务器", "Connected, \(servers.count) servers"))
        } catch {
            status = (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
