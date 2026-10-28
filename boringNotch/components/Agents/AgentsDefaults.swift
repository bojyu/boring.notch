//
//  AgentsDefaults.swift
//  boringNotch
//
//  Settings for the Agents tab: agent quotas from the Dmit quota hub, read by agent-hud's AgentHUDCore.
//

import Defaults
import Foundation

extension Defaults.Keys {
    /// Shows the Agents tab and runs the quota collection behind it. Off by default, so the app is the stock one until
    /// it is switched on.
    static let agentsTabEnabled = Key<Bool>("agentsTabEnabled", default: false)
    /// The notch reopens on the Agents tab when it was closed there, instead of going back to Home.
    static let agentsStayOnTab = Key<Bool>("agentsStayOnTab", default: true)
    /// The Dmit quota hub's address, under which `api/quota` is served.
    static let agentsHubURL = Key<String>("agentsHubURL", default: "https://jev.bojyu.world:8443/quota/")
    /// The hub's user name; its password is in the keychain (`AgentCredentialStore`).
    static let agentsHubUser = Key<String>("agentsHubUser", default: "")
    /// Vendor marks left off the tab.
    static let agentsHiddenVendors = Key<Set<String>>("agentsHiddenVendors", default: [])
}
