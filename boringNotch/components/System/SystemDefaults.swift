//
//  SystemDefaults.swift
//  boringNotch
//
//  Settings for the System tab: this Mac's live load.
//

import Defaults

extension Defaults.Keys {
    /// Shows the System tab. Off by default, so the app is the stock one until it is switched on; nothing is
    /// sampled unless the tab is on screen.
    static let systemTabEnabled = Key<Bool>("systemTabEnabled", default: false)
    /// The notch reopens on the System tab when it was closed there, instead of going back to Home.
    static let systemStayOnTab = Key<Bool>("systemStayOnTab", default: true)
}
