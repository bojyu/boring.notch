//
//  AgentQuotaManager.swift
//  boringNotch
//
//  Runs agent-hud's Dmit quota collection while the Agents tab is switched on, and nothing while it is off.
//

import AgentHUDCore
import Combine
import Defaults
import Foundation
import Observation

@MainActor
@Observable
final class AgentQuotaManager {
    static let shared = AgentQuotaManager()

    /// The collected readings; nil while the tab is off.
    private(set) var store: UsageStore?
    /// A hub collection asked for by hand is running.
    private(set) var isRequesting = false

    @ObservationIgnored private var hub: DmitHubProvider?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var ledger: UsageLedger?
    @ObservationIgnored private var enabledObserver: AnyCancellable?

    private init() {}

    /// Follows the tab's switch from launch on: collecting while it is on, stopped while it is off.
    func activate() {
        enabledObserver = Defaults.publisher(.agentsTabEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in
                    guard let self else { return }
                    if enabled { self.start() } else { self.stop() }
                }
            }
    }

    var hasCredentials: Bool {
        let user = Defaults[.agentsHubUser]
        return !user.isEmpty && AgentCredentialStore.password(for: user) != nil
    }

    /// Builds the store again, for a new address or new credentials.
    func restart() {
        stop()
        if Defaults[.agentsTabEnabled] { start() }
    }

    /// Asks the hub to read every channel now, then reads its answer.
    func requestCollection() async {
        guard let hub, let store, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        try? await hub.requestCollection()
        await store.refresh()
    }

    private func start() {
        guard store == nil else { return }
        // DeepSeek's balance comes from the hub, which was asked to read it, so it shows at once (as in agent-hud).
        VendorCatalog.shownAtOnce = ["DeepSeek"]
        let settings = settings ?? UsageAssembly.settings(defaults: UserDefaults(suiteName: "theboringteam.boringnotch.agents.hud") ?? .standard)
        let ledger = ledger ?? UsageLedger.open()
        self.settings = settings
        self.ledger = ledger
        let base = URL(string: Defaults[.agentsHubURL].trimmingCharacters(in: .whitespacesAndNewlines))
        let hub = DmitHubProvider.standard(ledger: ledger, base: base, authorization: Self.authorization)
        let store = UsageAssembly.dmitStore(settings: settings, hub: hub, ledger: ledger)
        self.hub = hub
        self.store = store
        store.start()
    }

    private func stop() {
        store?.stop()
        store = nil
        hub = nil
    }

    /// The hub's `Basic` header from the settings' user and the keychain's password, read for every request.
    private nonisolated static let authorization: @Sendable () -> String? = {
        let user = Defaults[.agentsHubUser]
        guard let password = AgentCredentialStore.password(for: user) else { return nil }
        return DmitHubProvider.basicAuthorization(user: user, password: password)
    }
}
