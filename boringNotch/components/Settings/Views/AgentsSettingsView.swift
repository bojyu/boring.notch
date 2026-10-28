//
//  AgentsSettingsView.swift
//  boringNotch
//
//  Settings for the Agents tab: the switch, the Dmit hub's account, and which vendors show.
//

import AgentHUDCore
import Defaults
import SwiftUI

struct AgentsSettingsView: View {
    @Default(.agentsTabEnabled) private var enabled
    @Default(.agentsHubURL) private var hubURL
    @Default(.agentsHubUser) private var hubUser
    @Default(.agentsHiddenVendors) private var hidden
    @State private var password = ""
    @State private var status: (ok: Bool, text: String)?
    @State private var testing = false
    private let manager = AgentQuotaManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("显示 Agents 标签", "Show the Agents tab"), isOn: $enabled)
                Defaults.Toggle(key: .agentsStayOnTab) {
                    Text(L10n.text("收起后停留在 Agents 页", "Stay on Agents after the notch closes"))
                }
                .disabled(!enabled)
            } footer: {
                Text(L10n.text("在刘海展开后的标签栏里显示各家 AI agent 的额度，数据来自 Dmit 配额中心。关闭时不读取任何数据。",
                               "Shows AI agent quotas from the Dmit quota hub in its own tab. Nothing is read while it is off."))
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(L10n.text("地址", "Address"), text: $hubURL)
                TextField(L10n.text("用户名", "User"), text: $hubUser)
                SecureField(L10n.text("密码", "Password"), text: $password)
                HStack {
                    Button(L10n.text("保存", "Save")) { save() }
                    Button(L10n.text("测试连接", "Test connection")) { Task { await test() } }
                        .disabled(testing || hubUser.isEmpty || password.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if let status {
                        Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(status.ok ? .green : .red)
                            .lineLimit(2)
                    }
                }
            } header: {
                Text(L10n.text("Dmit 配额中心", "Dmit quota hub"))
            } footer: {
                Text(L10n.text("密码保存在本机钥匙串里。", "The password is kept in this Mac's keychain."))
                    .foregroundStyle(.secondary)
            }

            if let store = manager.store {
                let vendors = AgentTile.tiles(store, hidden: [])
                if !vendors.isEmpty {
                    Section {
                        ForEach(vendors) { tile in
                            Toggle(isOn: Binding(get: { !hidden.contains(tile.id) },
                                                 set: { shown in
                                                     if shown { hidden.remove(tile.id) } else { hidden.insert(tile.id) }
                                                 })) {
                                HStack(spacing: 8) {
                                    AgentLogo(vendor: tile.vendor)
                                        .frame(width: 16, height: 16)
                                        .padding(3)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black))
                                    Text(tile.name)
                                }
                            }
                        }
                    } header: {
                        Text(L10n.text("显示哪些", "Shown vendors"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
        .onAppear { password = AgentCredentialStore.password(for: hubUser) ?? "" }
        .onChange(of: enabled) { _, on in
            if !on, BoringViewCoordinator.shared.currentView == .agents {
                BoringViewCoordinator.shared.currentView = .home
            }
        }
    }

    private func save() {
        let saved = AgentCredentialStore.setPassword(password, for: hubUser)
        status = saved ? (true, L10n.text("已保存", "Saved")) : (false, L10n.text("保存失败", "Could not save"))
        manager.restart()
    }

    /// Reads `api/quota` once with what is typed, without saving it.
    private func test() async {
        testing = true
        defer { testing = false }
        guard let base = URL(string: hubURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = (false, L10n.text("地址无效", "Invalid address"))
            return
        }
        var request = URLRequest(url: base.appendingPathComponent("api/quota"), timeoutInterval: 15)
        request.setValue(DmitHubProvider.basicAuthorization(user: hubUser, password: password), forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: status = (true, L10n.text("连接成功", "Connected"))
            case 401, 403: status = (false, L10n.text("用户名或密码不对", "Wrong user or password"))
            default: status = (false, "HTTP \(code)")
            }
        } catch {
            status = (false, error.localizedDescription)
        }
    }
}
