//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
]

let agentsTab = TabModel(label: "Agents", icon: "gauge.with.dots.needle.67percent", view: .agents)
let systemTab = TabModel(label: "System", icon: "cpu", view: .system)
let serversTab = TabModel(label: "Servers", icon: "server.rack", view: .servers)

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var shelfState = ShelfStateViewModel.shared
    @Default(.agentsTabEnabled) var agentsTabEnabled
    @Default(.systemTabEnabled) var systemTabEnabled
    @Default(.serversTabEnabled) var serversTabEnabled
    @Namespace var animation

    /// Home and Shelf as the header has always shown them, then Agents, System and Servers while each is switched on.
    private var shownTabs: [TabModel] {
        let showsShelf = (!shelfState.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf]
        var shown = showsShelf ? tabs : tabs.filter { $0.view != .shelf }
        if agentsTabEnabled { shown.append(agentsTab) }
        if systemTabEnabled { shown.append(systemTab) }
        if serversTabEnabled { shown.append(serversTab) }
        return shown
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(shownTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
