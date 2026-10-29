//
//  SystemSettingsView.swift
//  boringNotch
//
//  Settings for the System tab.
//

import AgentHUDCore
import Defaults
import SwiftUI

struct SystemSettingsView: View {
    @Default(.systemTabEnabled) private var enabled

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("显示 System 标签", "Show the System tab"), isOn: $enabled)
                Defaults.Toggle(key: .systemStayOnTab) {
                    Text(L10n.text("收起后停留在 System 页", "Stay on System after the notch closes"))
                }
                .disabled(!enabled)
            } footer: {
                Text(L10n.text("在刘海展开后的标签栏里显示本机的 CPU、内存、GPU、网络、磁盘和电池状态，每秒更新。只在这个标签页打开时读取。",
                               "Shows this Mac's CPU, memory, GPU, network, disk and battery in its own tab, updated every second. It only reads while the tab is open."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("System")
        .onChange(of: enabled) { _, on in
            if !on, BoringViewCoordinator.shared.currentView == .system {
                BoringViewCoordinator.shared.currentView = .home
            }
        }
    }
}
