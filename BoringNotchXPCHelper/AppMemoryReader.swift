//
//  AppMemoryReader.swift
//  BoringNotchXPCHelper
//
//  Sums each app's memory over all its processes. It runs in the helper because the sandboxed app may not read
//  other processes.
//

import Darwin
import Foundation

enum AppMemoryReader {
    /// The apps (and loose processes) holding the most memory, largest first.
    static func topApps(limit: Int) -> [AppMemoryUsage] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }

        var groups: [String: (name: String, bundle: String?, bytes: UInt64, count: Int)] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0, usage.ri_phys_footprint > 0 else { continue }
            let (key, name, bundle) = owner(of: pid)
            var group = groups[key] ?? (name, bundle, 0, 0)
            group.bytes += usage.ri_phys_footprint
            group.count += 1
            groups[key] = group
        }
        return groups.map { key, group in
            AppMemoryUsage(id: key, name: group.name, bundlePath: group.bundle, bytes: group.bytes, processCount: group.count)
        }
        .sorted { $0.bytes > $1.bytes }
        .prefix(max(0, limit))
        .map { $0 }
    }

    /// The process macOS holds responsible for another (the app that launched its XPC services and web content), as
    /// Activity Monitor groups them. It is private API, looked up at run time; without it each process stands alone.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    /// The outermost `.app` the process, or the one responsible for it, runs from; otherwise the process itself.
    private static func owner(of pid: pid_t) -> (key: String, name: String, bundle: String?) {
        let owners = [responsible.map { $0(pid) }, pid].compactMap { $0 }.filter { $0 > 0 }
        for candidate in owners {
            // The outermost bundle wins, so an app's helper apps and extensions count towards the app itself.
            if let path = path(of: candidate),
               let range = [".app/", ".appex/"].compactMap({ path.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                let bundle = String(path[..<range.upperBound].dropLast())
                return (bundle, appName(bundle), bundle)
            }
        }
        var name = [CChar](repeating: 0, count: 256)
        let processName = proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : "PID \(pid)"
        return ("process:" + processName, processName, nil)
    }

    private static var names: [String: String] = [:]

    private static func appName(_ bundle: String) -> String {
        if let name = names[bundle] { return name }
        // An extension's display name is often a bare word ("Web"), so its file name says more.
        if bundle.hasSuffix(".appex") { return URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent }
        let info = Bundle(path: bundle)?.localizedInfoDictionary ?? Bundle(path: bundle)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
        names[bundle] = name
        return name
    }
}
