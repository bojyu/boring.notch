//
//  SystemMonitor.swift
//  boringNotch
//
//  Live readings of this Mac: CPU, memory, GPU, network, disk and power. It samples once a second, and only while
//  the System tab is on screen.
//

import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

/// One reading of the whole machine.
struct SystemSample: Equatable {
    var cpu: Double = 0
    /// Each logical core's use, 0...100, in the kernel's order.
    var cores: [Double] = []
    var performanceCores: Double?
    var efficiencyCores: Double?

    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memoryCached: UInt64 = 0
    /// The parts of the used memory, as Activity Monitor splits it.
    var memoryApp: UInt64 = 0
    var memoryWired: UInt64 = 0
    var memoryCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// The kernel's memory pressure: 1 normal, 2 warning, 4 critical.
    var memoryPressure: Int32?

    var gpu: Double?

    var networkIn: Double = 0
    var networkOut: Double = 0

    var diskTotal: Int64?
    var diskFree: Int64?
    var diskRead: Double = 0
    var diskWrite: Double = 0

    var battery: Int?
    var isCharging = false
    var onAC = false
    /// Watts flowing out of the battery (positive) or into it (negative).
    var batteryWatts: Double?

    var thermal: ProcessInfo.ThermalState = .nominal
    var load: (Double, Double, Double) = (0, 0, 0)
    var uptime: TimeInterval = 0

    var memoryPct: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) * 100 }
    var diskUsedPct: Double? {
        guard let diskTotal, let diskFree, diskTotal > 0 else { return nil }
        return Double(diskTotal - diskFree) / Double(diskTotal) * 100
    }

    static func == (a: SystemSample, b: SystemSample) -> Bool {
        a.cpu == b.cpu && a.cores == b.cores && a.memoryUsed == b.memoryUsed && a.gpu == b.gpu
            && a.networkIn == b.networkIn && a.networkOut == b.networkOut && a.diskRead == b.diskRead
            && a.diskWrite == b.diskWrite && a.battery == b.battery && a.batteryWatts == b.batteryWatts
            && a.thermal == b.thermal
    }
}

@MainActor
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    private(set) var sample = SystemSample()
    /// The last minute, oldest first.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var networkInHistory: [Double] = []
    private(set) var networkOutHistory: [Double] = []
    /// Nothing is shown until two readings make the first rates.
    private(set) var isReady = false
    /// The apps holding the most memory, from the helper (the sandbox hides other processes); nil until it answers.
    private(set) var apps: [AppMemoryUsage]?

    static let historyLength = 60

    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var reader = SystemReader()
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var askingApps = false

    private init() {}

    /// A view showing the readings appeared; sampling runs while at least one does.
    func attach() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    private func tick() {
        // Walking every process costs more than the counters, so the apps are asked for every third second.
        if ticks % 3 == 0, !askingApps {
            askingApps = true
            Task { [weak self] in
                let apps = await XPCHelperClient.shared.appMemoryUsage(limit: 4)
                guard let self else { return }
                if let apps { self.apps = apps }
                self.askingApps = false
            }
        }
        ticks += 1
        guard let next = reader.read() else { return }
        sample = next
        isReady = true
        Self.push(next.cpu, to: &cpuHistory)
        Self.push(next.memoryPct, to: &memoryHistory)
        Self.push(next.networkIn, to: &networkInHistory)
        Self.push(next.networkOut, to: &networkOutHistory)
    }

    private static func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}

/// Reads the counters and turns the ones that only grow into rates since the last read.
private struct SystemReader {
    private var lastTicks: [[UInt32]] = []
    private var lastNetwork: (UInt64, UInt64)?
    private var lastDisk: (UInt64, UInt64)?
    private var lastAt: Date?

    private let efficiencyCount = Self.sysctlInt("hw.perflevel1.logicalcpu")
    private let performanceCount = Self.sysctlInt("hw.perflevel0.logicalcpu")

    /// nil for the first call, which only sets the baselines.
    mutating func read() -> SystemSample? {
        let now = Date()
        let elapsed = lastAt.map { now.timeIntervalSince($0) } ?? 0
        defer { lastAt = now }

        var sample = SystemSample()
        let ticks = Self.coreTicks()
        let network = Self.networkBytes()
        let disk = Self.diskBytes()
        defer {
            lastTicks = ticks
            lastNetwork = network
            lastDisk = disk
        }
        guard elapsed > 0, ticks.count == lastTicks.count else { return nil }

        // CPU: the share of non-idle ticks per core since the last read.
        var busyAll = 0.0, totalAll = 0.0
        sample.cores = zip(ticks, lastTicks).map { now, before in
            let delta = (0..<Int(CPU_STATE_MAX)).map { Double(now[$0] &- before[$0]) }
            let total = delta.reduce(0, +)
            let busy = total - delta[Int(CPU_STATE_IDLE)]
            busyAll += busy
            totalAll += total
            return total > 0 ? busy / total * 100 : 0
        }
        sample.cpu = totalAll > 0 ? busyAll / totalAll * 100 : 0
        // Apple silicon lists the efficiency cores first.
        if let efficiencyCount, let performanceCount, efficiencyCount + performanceCount == sample.cores.count {
            let average = { (cores: ArraySlice<Double>) in cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count) }
            sample.efficiencyCores = average(sample.cores.prefix(efficiencyCount))
            sample.performanceCores = average(sample.cores.suffix(performanceCount))
        }

        Self.readMemory(into: &sample)
        sample.gpu = Self.gpuUtilization()

        if let network, let lastNetwork {
            sample.networkIn = Double(network.0 &- lastNetwork.0) / elapsed
            sample.networkOut = Double(network.1 &- lastNetwork.1) / elapsed
            if network.0 < lastNetwork.0 || network.1 < lastNetwork.1 { sample.networkIn = 0; sample.networkOut = 0 }
        }
        if let disk, let lastDisk, disk.0 >= lastDisk.0, disk.1 >= lastDisk.1 {
            sample.diskRead = Double(disk.0 - lastDisk.0) / elapsed
            sample.diskWrite = Double(disk.1 - lastDisk.1) / elapsed
        }
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                                               .volumeAvailableCapacityForImportantUsageKey]) {
            sample.diskTotal = values.volumeTotalCapacity.map(Int64.init)
            sample.diskFree = values.volumeAvailableCapacityForImportantUsage
        }

        Self.readPower(into: &sample)
        sample.thermal = ProcessInfo.processInfo.thermalState
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { sample.load = (load[0], load[1], load[2]) }
        sample.uptime = ProcessInfo.processInfo.systemUptime
        return sample
    }

    // MARK: CPU

    private static func coreTicks() -> [[UInt32]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
        }
    }

    // MARK: Memory

    private static func readMemory(into sample: inout SystemSample) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // As Activity Monitor counts it: app memory, wired and compressed.
            let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
            sample.memoryApp = app * page
            sample.memoryWired = UInt64(stats.wire_count) * page
            sample.memoryCompressed = UInt64(stats.compressor_page_count) * page
            sample.memoryUsed = sample.memoryApp + sample.memoryWired + sample.memoryCompressed
            sample.memoryCached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            sample.swapUsed = swap.xsu_used
            sample.swapTotal = swap.xsu_total
        }
        var pressure: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 { sample.memoryPressure = pressure }
    }

    // MARK: GPU and disk (IOKit registry)

    private static func registryValues(_ className: String, _ key: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var values: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                values.append(value)
            }
            IOObjectRelease(service)
        }
        return values
    }

    private static func gpuUtilization() -> Double? {
        let values = registryValues("IOAccelerator", "PerformanceStatistics")
            .compactMap { ($0["Device Utilization %"] as? NSNumber)?.doubleValue }
        return values.max()
    }

    private static func diskBytes() -> (UInt64, UInt64)? {
        let stats = registryValues("IOBlockStorageDriver", "Statistics")
        guard !stats.isEmpty else { return nil }
        let read = stats.compactMap { ($0["Bytes (Read)"] as? NSNumber)?.uint64Value }.reduce(0, +)
        let write = stats.compactMap { ($0["Bytes (Write)"] as? NSNumber)?.uint64Value }.reduce(0, +)
        return (read, write)
    }

    // MARK: Network

    /// Bytes in and out over every interface but loopback, from the 64-bit counters.
    private static func networkBytes() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var received: UInt64 = 0, sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0 {
                        received += message.ifm_data.ifi_ibytes
                        sent += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    // MARK: Power

    private static func readPower(into sample: inout SystemSample) {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    sample.battery = current * 100 / max
                }
                sample.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
                sample.onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?
                .doubleValue
        }
        // Amperage is a signed milliamp figure stored as an unsigned register on some models.
        if let voltage = number("Voltage"), var amperage = number("Amperage") {
            if amperage > Double(Int32.max) { amperage -= Double(UInt64.max) + 1 }
            sample.batteryWatts = -(voltage * amperage) / 1_000_000
        }
    }

    // MARK: sysctl

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}
