//
//  AgentQuotaView.swift
//  boringNotch
//
//  The Agents tab: every vendor's quota ring along the top, and the chosen vendor's windows below.
//

import AgentHUDCore
import Defaults
import SwiftUI

/// One mark on the tab: a vendor's windows, or an API balance with no window.
struct AgentTile: Identifiable, Equatable {
    let id: String
    let vendor: String
    let usedPct: Double?
    let level: StatusLevel?
    /// A balance standing where the percentage would, for a vendor billed by use.
    let balance: String?
    let rows: [AgentRow]
    let billing: APIBilling?

    var name: String { VendorCatalog.name(vendor) }
    var figure: String { usedPct.map { "\(Int($0.rounded()))%" } ?? balance ?? "–" }

    /// The marks in row order, then the balances whose vendor has no window, without the hidden ones.
    @MainActor
    static func tiles(_ store: UsageStore, hidden: Set<String>) -> [AgentTile] {
        var tiles = VendorQuotaSummary.summaries(rows: store.rows).map { summary in
            AgentTile(id: summary.markKey, vendor: summary.vendor, usedPct: summary.usedPct, level: summary.level,
                      balance: nil, rows: summary.rows, billing: nil)
        }
        for billing in store.enabledBilling {
            let key = VendorMark.key(billing.vendor)
            guard !tiles.contains(where: { $0.id == key }) else { continue }
            let text = billing.balances.first.map { MoneyFormat.amount($0.total, currency: $0.currency) }
            tiles.append(AgentTile(id: key, vendor: billing.vendor, usedPct: nil, level: store.view.level(of: billing),
                                   balance: text, rows: [], billing: billing))
        }
        let rank = { (tile: AgentTile) in order.firstIndex(of: tile.id) ?? order.count }
        return tiles.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .filter { !hidden.contains($0.id) }
    }

    /// Subscriptions first, then the API rings, then balances; a mark not listed keeps its place after them.
    private static let order = ["Claude", "ChatGPT", "Antigravity", "Muse", "Notion", "Anthropic API",
                                "DeepSeek", "OpenRouter", "Kie"]
}

struct AgentQuotaView: View {
    @Default(.agentsHiddenVendors) private var hidden
    @State private var selection: String?
    private let manager = AgentQuotaManager.shared

    var body: some View {
        Group {
            if !manager.hasCredentials {
                notice(icon: "key.horizontal", text: L10n.text("填好 Dmit 配额中心的账号后，这里会显示各家额度",
                                                                "Add your Dmit quota hub account to see agent quotas"),
                       action: L10n.text("去设置", "Open Settings")) {
                    SettingsWindowController.shared.showWindow()
                }
            } else if let store = manager.store {
                let tiles = AgentTile.tiles(store, hidden: hidden)
                if tiles.isEmpty {
                    notice(icon: store.lastError == nil ? "hourglass" : "exclamationmark.triangle",
                           text: store.lastError ?? L10n.text("正在读取 Dmit 配额中心…", "Reading the Dmit quota hub…"))
                } else {
                    content(store, tiles: tiles)
                }
            } else {
                notice(icon: "hourglass", text: L10n.text("正在启动…", "Starting…"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Content

    private func content(_ store: UsageStore, tiles: [AgentTile]) -> some View {
        let chosen = tiles.first { $0.id == selection } ?? tiles[0]
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tiles) { tile in
                            tileView(tile, selected: tile.id == chosen.id)
                        }
                    }
                }
                .scrollClipDisabled()
                AgentDetailView(tile: chosen, store: store, now: context.date, isRequesting: manager.isRequesting) {
                    Task { await manager.requestCollection() }
                }
                .id(chosen.id)
                .transition(.opacity)
            }
            .animation(.smooth(duration: 0.3), value: chosen.id)
        }
    }

    private func tileView(_ tile: AgentTile, selected: Bool) -> some View {
        Button {
            selection = tile.id
        } label: {
            VStack(spacing: 4) {
                AgentRingMark(vendor: tile.vendor, usedPct: tile.usedPct, level: tile.level, size: 34)
                Text(tile.figure)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tile.usedPct == nil && tile.balance == nil ? AgentPalette.secondary : AgentPalette.color(tile.level))
                    .lineLimit(1)
            }
            .frame(width: 62, height: 58)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.1 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tile.name)
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

/// The chosen vendor: its name and plan, when it was last read, and a line per window or amount.
private struct AgentDetailView: View {
    let tile: AgentTile
    let store: UsageStore
    let now: Date
    let isRequesting: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tile.rows) { row in windowLine(row) }
                    ForEach(amounts, id: \.label) { amountLine($0.label, $0.value) }
                    if let issue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(AgentPalette.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(tile.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if let plan = store.view.subscriptions[tile.vendor] {
                Text(plan)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AgentPalette.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Spacer(minLength: 8)
            if let updated {
                Text(L10n.text("更新于 ", "Updated ") + updated)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(AgentPalette.secondary)
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AgentPalette.secondary)
                    .rotationEffect(.degrees(isRequesting ? 360 : 0))
                    .animation(isRequesting ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: isRequesting)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)
            .help(L10n.text("让配额中心马上读取一次", "Ask the hub to read every channel now"))
        }
    }

    private func windowLine(_ row: AgentRow) -> some View {
        let used = row.assessment.showsLevel ? row.usedPct : nil
        let color = AgentPalette.color(row.level)
        return HStack(spacing: 10) {
            Text(row.agent.shortName)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AgentPalette.track)
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * max(0, min(1, (used ?? 0) / 100)))
                        .opacity(used == nil ? 0 : 1)
                }
            }
            .frame(height: 5)
            .animation(.smooth(duration: 0.45), value: used)
            Text(used.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(used == nil ? AgentPalette.secondary : color)
                .frame(width: 38, alignment: .trailing)
            Text(row.resetAt == nil ? "" : row.resetLabel(now: now, compact: true))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(AgentPalette.secondary)
                .lineLimit(1)
                .frame(width: 62, alignment: .trailing)
        }
        .frame(height: 14)
    }

    private func amountLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 96, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(height: 14)
    }

    /// A balance, its granted and topped-up parts, and an account's wallets (this month's API spend, a prepaid balance).
    private var amounts: [(label: String, value: String)] {
        var lines: [(String, String)] = []
        if let balance = tile.billing?.balances.first {
            lines.append((L10n.text("余额", "Balance"), MoneyFormat.amount(balance.total, currency: balance.currency)))
        }
        let wallets = tile.rows.compactMap(\.account?.wallets).first ?? []
        for wallet in wallets {
            switch wallet.kind {
            case .monthlySpend:
                if let used = wallet.used {
                    lines.append((L10n.text("本月 API 花费", "API spend this month"), MoneyFormat.amount(used, currency: wallet.currency)))
                }
            case .prepaid, .onDemand:
                if let balance = wallet.balance {
                    lines.append((L10n.text("API 余额", "API balance"), MoneyFormat.amount(balance, currency: wallet.currency)))
                }
            }
        }
        return lines
    }

    /// Why the vendor's reading is held back, as the hub or the request said.
    private var issue: String? {
        tile.billing?.readingIssue?.reason
            ?? tile.rows.lazy.compactMap { $0.account?.readingIssue?.reason ?? $0.account?.quotaNotice }.first
    }

    /// How long ago the vendor was last read, from its own readings.
    private var updated: String? {
        let times = tile.rows.compactMap(\.assessment.observedAt) + [tile.billing?.updatedAt].compactMap { $0 }
        guard let last = times.max() else { return nil }
        if now.timeIntervalSince(last) < 60 { return L10n.text("刚刚", "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: L10n.text("zh_CN", "en_US"))
        return formatter.localizedString(for: last, relativeTo: now)
    }
}
