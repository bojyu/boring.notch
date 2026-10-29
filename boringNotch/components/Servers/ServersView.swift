//
//  ServersView.swift
//  boringNotch
//
//  The Servers tab: the servers a Beszel hub watches, drawn in the Agents tab's style.
//

import AgentHUDCore
import Defaults
import SwiftUI

struct ServersView: View {
    @State private var selection: String?
    private let monitor = ServerMonitor.shared

    var body: some View {
        Group {
            if !monitor.hasCredentials {
                notice(icon: "key.horizontal", text: L10n.text("填好 Beszel 的账号后，这里会显示各台服务器",
                                                                "Add your Beszel account to see your servers"),
                       action: L10n.text("去设置", "Open Settings")) {
                    SettingsWindowController.shared.showWindow()
                }
            } else if monitor.servers.isEmpty {
                notice(icon: monitor.lastError == nil ? "hourglass" : "exclamationmark.triangle",
                       text: monitor.lastError ?? (monitor.lastRead == nil ? L10n.text("正在读取 Beszel…", "Reading Beszel…")
                                                                         : L10n.text("这个账号下还没有服务器", "No servers on this account")))
            } else {
                content(monitor.servers)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { monitor.attach() }
        .onDisappear { monitor.detach() }
    }

    private func content(_ servers: [BeszelServer]) -> some View {
        let chosen = servers.first { $0.id == selection } ?? servers[0]
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(servers) { server in
                            tile(server, selected: server.id == chosen.id)
                        }
                    }
                }
                .scrollClipDisabled()
                ServerDetailView(server: chosen, now: context.date, monitor: monitor)
                    .id(chosen.id)
                    .transition(.opacity)
            }
            .animation(.smooth(duration: 0.3), value: chosen.id)
        }
    }

    private func tile(_ server: BeszelServer, selected: Bool) -> some View {
        let online = server.status == .up
        let level = online ? server.worstPct.map(ServerFormat.level) : nil
        return Button {
            selection = server.id
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().stroke(AgentPalette.track, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: online ? max(0, min(1, (server.worstPct ?? 0) / 100)) : 0)
                        .stroke(AgentPalette.color(level), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: online ? "server.rack" : "bolt.horizontal.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(online ? .white.opacity(0.85) : ServerFormat.statusColor(server.status))
                }
                .frame(width: 34, height: 34)
                .animation(.smooth(duration: 0.45), value: server.worstPct)
                Text(server.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(online ? AgentPalette.color(level) : AgentPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 62, height: 58)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.1 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(server.name + (server.host.isEmpty ? "" : " · " + server.host))
    }

    private func notice(icon: String, text: String, action: String? = nil, perform: (() -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AgentPalette.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(AgentPalette.secondary)
                .multilineTextAlignment(.center)
            if let action, let perform {
                Button(action, action: perform)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The chosen server: its state and when the hub heard from it, a bar per resource, and the rest as figures.
private struct ServerDetailView: View {
    let server: BeszelServer
    let now: Date
    let monitor: ServerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            HStack(alignment: .top, spacing: 18) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        bar("CPU", server.cpu)
                        bar(L10n.text("内存", "Memory"), server.memory)
                        bar(server.diskName ?? L10n.text("磁盘", "Disk"), server.disk)
                        ForEach(server.extraDisks, id: \.name) { bar($0.name, $0.pct) }
                        if let gpu = server.gpu { bar("GPU", gpu) }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(facts, id: \.0) { fact(icon: $0.0, $0.1, warn: $0.2) }
                }
                .frame(width: 168, alignment: .leading)
            }
        }
        .padding(.horizontal, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(server.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(ServerFormat.statusName(server.status))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(ServerFormat.statusColor(server.status))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(ServerFormat.statusColor(server.status).opacity(0.14)))
            if !server.host.isEmpty {
                Text(server.host)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(AgentPalette.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if let error = monitor.lastError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentPalette.warning)
                    .help(error)
            }
            if let updated = server.updated {
                Text(ServerFormat.ago(updated, now: now))
                    .font(.system(size: 9.5))
                    .foregroundStyle(AgentPalette.secondary)
            }
            Button {
                Task { await monitor.read() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .rotationEffect(.degrees(monitor.isReading ? 360 : 0))
                    .animation(monitor.isReading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: monitor.isReading)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(monitor.isReading)
            .help(L10n.text("立即读取", "Read now"))
        }
    }

    /// Network, load, temperature, uptime, services and updates, each only when the agent reports it.
    private var facts: [(String, String, Bool)] {
        var lines: [(String, String, Bool)] = []
        if let bandwidth = server.bandwidth {
            lines.append(("arrow.up.arrow.down", SystemStatusView.rateText(bandwidth), false))
        }
        if server.load.count == 3 {
            let busy = server.threads.map { server.load[0] > Double($0) } ?? false
            lines.append(("gauge.with.needle", L10n.text("负载 ", "Load ")
                + server.load.map { String(format: "%.2f", $0) }.joined(separator: " "), busy))
        }
        if let temperature = server.temperature {
            lines.append(("thermometer.medium", String(format: "%.0f °C", temperature), temperature >= 80))
        }
        if let uptime = server.uptime {
            lines.append(("clock", L10n.text("已运行 ", "Up ") + ServerFormat.uptime(uptime), false))
        }
        if server.services.count >= 2 {
            let failed = server.services[1]
            lines.append(("gearshape.2", failed > 0 ? L10n.text("\(failed) 个服务失败", "\(failed) services failed")
                                                    : L10n.text("服务 \(server.services[0]) 个正常", "\(server.services[0]) services OK"),
                          failed > 0))
        }
        if let total = server.updates.first, total > 0 {
            let security = server.updates.count > 1 ? server.updates[1] : 0
            lines.append(("arrow.down.circle", L10n.text("\(total) 个更新", "\(total) updates")
                + (security > 0 ? L10n.text("（安全 \(security)）", " (\(security) security)") : ""), security > 0))
        }
        return Array(lines.prefix(4))
    }

    private func bar(_ name: String, _ value: Double?) -> some View {
        let online = server.status == .up
        let shown = online ? value : nil
        let color = AgentPalette.color(shown.map(ServerFormat.level))
        return HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AgentPalette.track)
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * max(0, min(1, (shown ?? 0) / 100)))
                }
            }
            .frame(height: 5)
            .animation(.smooth(duration: 0.45), value: shown)
            Text(shown.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(shown == nil ? AgentPalette.secondary : color)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: 14)
    }

    private func fact(icon: String, _ text: String, warn: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(AgentPalette.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(warn ? AgentPalette.warning : .white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: 14)
    }
}

enum ServerFormat {
    static func level(_ pct: Double) -> StatusLevel { pct >= 90 ? .critical : pct >= 75 ? .warning : .ok }

    static func statusName(_ status: BeszelServer.Status) -> String {
        switch status {
        case .up: L10n.text("在线", "Up")
        case .down: L10n.text("离线", "Down")
        case .paused: L10n.text("已暂停", "Paused")
        case .pending: L10n.text("等待中", "Pending")
        }
    }

    static func statusColor(_ status: BeszelServer.Status) -> Color {
        switch status {
        case .up: Color(red: 0.3, green: 0.85, blue: 0.5)
        case .down: AgentPalette.critical
        case .paused, .pending: AgentPalette.secondary
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return L10n.text("刚刚", "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds) / 60
        let days = total / 1440, hours = total / 60 % 24, minutes = total % 60
        if days > 0 { return L10n.text("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        if hours > 0 { return L10n.text("\(hours) 小时 \(minutes) 分", "\(hours)h \(minutes)m") }
        return L10n.text("\(minutes) 分", "\(minutes)m")
    }
}
