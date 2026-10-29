//
//  AppMemoryUsage.swift
//  boringNotch
//
//  The memory an app holds across all its processes, as the helper reads it for the System tab.
//

import Foundation

struct AppMemoryUsage: Codable, Equatable, Identifiable {
    /// The app's bundle path, or `process:<name>` for a process outside any app.
    let id: String
    let name: String
    /// The `.app` bundle, when the processes belong to one.
    let bundlePath: String?
    /// The summed footprint of its processes, as Activity Monitor's Memory column counts each.
    let bytes: UInt64
    let processCount: Int
}
