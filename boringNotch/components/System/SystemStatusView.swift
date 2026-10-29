//
//  SystemStatusView.swift
//  boringNotch
//
//  The System tab: this Mac's load at a glance, drawn in the Agents tab's style.
//

import AgentHUDCore
import SwiftUI

struct SystemStatusView: View {
    private let monitor = SystemMonitor.shared

    var body: some View {
        Group {
            if monitor.isReady {
                content(monitor.sample)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在读取本机状态…", "Reading this Mac…"))
                        .font(.system(size: 11))
                        .foregroundStyle(AgentPalette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { monitor.attach() }
        .onDisappear { monitor.detach() }
    }

    private func content(_ sample: SystemSample) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                memoryCard(sample)
                    .layoutPriority(1)
                processorCard(sample)
                    .frame(width: 124)
                networkCard(sample)
                    .frame(width: 98)
                diskCard(sample)
                    .frame(width: 88)
            }
            .frame(height: 112)
            statusStrip(sample)
        }
    }

    // MARK: Cards

    /// The parts of the memory, in Activity Monitor's order, with the colour each has in the bar.
    private static func memoryParts(_ sample: SystemSample) -> [(name: String, bytes: UInt64, color: Color)] {
        [(L10n.text("App 内存", "App memory"), sample.memoryApp, MemoryColors.app),
         (L10n.text("联动内存", "Wired"), sample.memoryWired, MemoryColors.wired),
         (L10n.text("被压缩", "Compressed"), sample.memoryCompressed, MemoryColors.compressed),
         (L10n.text("缓存文件", "Cached files"), sample.memoryCached, MemoryColors.cached)]
    }

    private func memoryCard(_ sample: SystemSample) -> some View {
        let level = Self.memoryLevel(sample)
        let parts = Self.memoryParts(sample)
        return SystemCard(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.text("内存", "Memory"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AgentPalette.secondary)
                    Text(Self.bytes(sample.memoryUsed, style: .memory))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AgentPalette.color(level))
                        .contentTransition(.numericText())
                    Text("/ " + Self.bytes(sample.memoryTotal, style: .memory))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(AgentPalette.secondary)
                    Spacer(minLength: 4)
                    Text(L10n.text("压力 ", "Pressure ") + Self.pressureName(sample.memoryPressure))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(level == .ok ? AgentPalette.secondary : AgentPalette.color(level))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill((level == .ok ? Color.white : AgentPalette.color(level)).opacity(0.12)))
                }
                MemoryBar(parts: parts.map { ($0.bytes, $0.color) }, total: sample.memoryTotal)
                    .frame(height: 7)
                    .help((parts.map { $0.name + " " + Self.bytes($0.bytes, style: .memory) }
                           + [L10n.text("交换 ", "Swap ") + Self.bytes(sample.swapUsed, style: .memory)]).joined(separator: "\n"))
                Group {
                    if let apps = monitor.apps, !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.text("占用最多的应用", "Largest apps"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(AgentPalette.secondary)
                            ForEach(apps) { app in
                                HStack(spacing: 4) {
                                    AppIcon(path: app.bundlePath)
                                        .frame(width: 13, height: 13)
                                    Text(app.name)
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 2)
                                    Text(Self.bytes(app.bytes, style: .memory))
                                        .monospacedDigit()
                                        .foregroundStyle(AgentPalette.secondary)
                                        .fixedSize()
                                }
                                .font(.system(size: 10.5))
                                .help(app.processCount > 1
                                      ? app.name + L10n.text("（\(app.processCount) 个进程）", " (\(app.processCount) processes)")
                                      : app.name)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Sparkline(values: monitor.memoryHistory, maximum: 100, color: AgentPalette.color(level))
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }

    /// CPU and GPU as two small rings, with the thermal state and load under them.
    private func processorCard(_ sample: SystemSample) -> some View {
        SystemCard {
            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    GaugeRing(value: sample.cpu, level: Self.level(sample.cpu), label: "CPU", size: 40)
                    GaugeRing(value: sample.gpu, level: sample.gpu.map(Self.level), label: "GPU", size: 40)
                }
                Text(L10n.text("温度 ", "Thermal ") + Self.thermalName(sample.thermal))
                    .font(.system(size: 9.5))
                    .foregroundStyle(sample.thermal == .nominal ? AgentPalette.secondary : AgentPalette.color(Self.thermalLevel(sample.thermal)))
                    .lineLimit(1)
                    .help(L10n.text("负载 ", "Load ") + String(format: "%.2f  %.2f  %.2f", sample.load.0, sample.load.1, sample.load.2))
            }
        }
    }

    private func networkCard(_ sample: SystemSample) -> some View {
        SystemCard {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("网络", "Network"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AgentPalette.secondary)
                rate("arrow.down", sample.networkIn)
                rate("arrow.up", sample.networkOut)
                ZStack {
                    let peak = max(monitor.networkInHistory.max() ?? 0, monitor.networkOutHistory.max() ?? 0, 1)
                    Sparkline(values: monitor.networkInHistory, maximum: peak, color: .white.opacity(0.8))
                    Sparkline(values: monitor.networkOutHistory, maximum: peak, color: AgentPalette.secondary, filled: false)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func diskCard(_ sample: SystemSample) -> some View {
        let used = sample.diskUsedPct
        let level: StatusLevel? = used.map { $0 >= 95 ? .critical : $0 >= 88 ? .warning : .ok }
        return SystemCard {
            VStack(spacing: 4) {
                GaugeRing(value: used, level: level, label: L10n.text("磁盘", "Disk"))
                Text(sample.diskFree.map { L10n.text("剩余 ", "Free ") + Self.bytes(UInt64($0), style: .file) } ?? "–")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Text("R " + Self.rateText(sample.diskRead, short: true) + " W " + Self.rateText(sample.diskWrite, short: true))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(AgentPalette.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .help(L10n.text("读 ", "Read ") + Self.rateText(sample.diskRead) + "\n" + L10n.text("写 ", "Write ") + Self.rateText(sample.diskWrite))
    }

    private func rate(_ icon: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(AgentPalette.secondary)
            Text(Self.rateText(value))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: Status strip

    private func statusStrip(_ sample: SystemSample) -> some View {
        HStack(spacing: 14) {
            if let battery = sample.battery {
                let low = battery <= 10 && !sample.onAC
                HStack(spacing: 4) {
                    Image(systemName: sample.isCharging ? "battery.100.bolt" : Self.batteryIcon(battery))
                    Text("\(battery)%").monospacedDigit()
                    if let watts = sample.batteryWatts, abs(watts) >= 0.1 {
                        Text(String(format: "%@%.1f W", watts < 0 ? "+" : "", abs(watts)))
                            .monospacedDigit()
                            .foregroundStyle(AgentPalette.secondary)
                            .help(watts < 0 ? L10n.text("正在充入电池", "Charging the battery")
                                            : L10n.text("电池正在供电", "Drawn from the battery"))
                    }
                    if sample.onAC && !sample.isCharging {
                        Text(L10n.text("已接电源", "On power")).foregroundStyle(AgentPalette.secondary)
                    }
                }
                .foregroundStyle(low ? AgentPalette.critical : .white.opacity(0.85))
            }
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text("\(sample.cores.count) " + L10n.text("核", "cores"))
            }
            .foregroundStyle(AgentPalette.secondary)
            Spacer(minLength: 0)
            Text(L10n.text("已运行 ", "Up ") + Self.uptimeText(sample.uptime))
                .monospacedDigit()
                .foregroundStyle(AgentPalette.secondary)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 4)
        .frame(height: 14)
    }

    // MARK: Formatting

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func level(_ pct: Double) -> StatusLevel { pct >= 90 ? .critical : pct >= 75 ? .warning : .ok }

    private static func memoryLevel(_ sample: SystemSample) -> StatusLevel {
        switch sample.memoryPressure {
        case 4: .critical
        case 2: .warning
        default: .ok
        }
    }

    private static func pressureName(_ level: Int32?) -> String {
        switch level {
        case 4: L10n.text("紧张", "Critical")
        case 2: L10n.text("偏高", "Elevated")
        case nil: "–"
        default: L10n.text("正常", "Normal")
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: L10n.text("正常", "Normal")
        case .fair: L10n.text("偏热", "Warm")
        case .serious: L10n.text("过热", "Hot")
        case .critical: L10n.text("严重", "Critical")
        @unknown default: "–"
        }
    }

    private static func thermalLevel(_ state: ProcessInfo.ThermalState) -> StatusLevel {
        switch state {
        case .nominal, .fair: .warning
        default: .critical
        }
    }

    private static func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }

    static func bytes(_ value: UInt64, style: ByteCountFormatter.CountStyle) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: style)
    }

    static func rateText(_ bytesPerSecond: Double, short: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = max(0, bytesPerSecond)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = value >= 100 || unit == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return number + (short ? units[unit].prefix(1) : " " + units[unit] + "/s")
    }

    private static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds) / 60
        let days = total / 1440, hours = total / 60 % 24, minutes = total % 60
        if days > 0 { return L10n.text("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        if hours > 0 { return L10n.text("\(hours) 小时 \(minutes) 分", "\(hours)h \(minutes)m") }
        return L10n.text("\(minutes) 分", "\(minutes)m")
    }
}

// MARK: Pieces

/// A translucent card on the notch's black, as the Agents tab's selected tile.
private struct SystemCard<Content: View>: View {
    var alignment: Alignment = .center
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
    }
}

/// A share as a ring, its figure inside and its name underneath, coloured only at a warning.
private struct GaugeRing: View {
    let value: Double?
    let level: StatusLevel?
    let label: String
    var size: CGFloat = 46

    private var fraction: Double { max(0, min(1, (value ?? 0) / 100)) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(AgentPalette.track, lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(AgentPalette.color(level), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(value == nil ? 0 : 1)
                Text(value.map(SystemStatusView.percent) ?? "–")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(value == nil ? AgentPalette.secondary : AgentPalette.color(level))
                    .contentTransition(.numericText())
            }
            .frame(width: size, height: size)
            .animation(.smooth(duration: 0.45), value: fraction)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AgentPalette.secondary)
        }
    }
}

/// The last minute as a line with a soft fill under it.
private struct Sparkline: View {
    let values: [Double]
    let maximum: Double
    let color: Color
    var filled = true

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, maximum > 0 else { return }
            let step = size.width / CGFloat(SystemMonitor.historyLength - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + step * CGFloat(index),
                        y: size.height - CGFloat(min(value, maximum) / maximum) * (size.height - 2) - 1)
            }
            var line = Path()
            line.addLines(points)
            if filled {
                var area = line
                area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .background(alignment: .bottom) {
            Rectangle().fill(AgentPalette.track).frame(height: 0.5)
        }
    }
}

/// An app's icon, or a neutral glyph for a process outside any app.
private struct AppIcon: View {
    let path: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let path {
            Image(nsImage: Self.icon(path)).resizable().scaledToFit()
        } else {
            Image(systemName: "gearshape").resizable().scaledToFit().foregroundStyle(AgentPalette.secondary)
        }
    }

    private static func icon(_ path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

/// Activity Monitor's colours for the memory parts, softened for the notch's black.
private enum MemoryColors {
    static let app = Color(red: 0.42, green: 0.68, blue: 1)
    static let wired = Color(red: 1, green: 0.66, blue: 0.3)
    static let compressed = Color(red: 0.78, green: 0.55, blue: 1)
    static let cached = Color.white.opacity(0.32)
}

/// The memory as one bar: each part's share of the total, the rest free.
private struct MemoryBar: View {
    let parts: [(bytes: UInt64, color: Color)]
    let total: UInt64

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(parts.indices, id: \.self) { index in
                    let share = total == 0 ? 0 : min(1, Double(parts[index].bytes) / Double(total))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(parts[index].color)
                        .frame(width: max(0, geometry.size.width * share - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(AgentPalette.track))
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .animation(.smooth(duration: 0.45), value: parts.map(\.bytes))
    }
}
