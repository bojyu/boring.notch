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
    let billings: [APIBilling]
    let accounts: [AccountObservation]
    let resetCredits: CodexResetCredits?

    var name: String { VendorCatalog.name(vendor) }
    var figure: String { usedPct.map { "\(Int($0.rounded()))%" } ?? balance ?? "–" }

    /// The marks in row order, then the balances whose vendor has no window, without the hidden ones.
    @MainActor
    static func tiles(_ store: UsageStore, hidden: Set<String>) -> [AgentTile] {
        tiles(view: store.view, report: store.report, hidden: hidden)
    }

    /// Account-only channels still have a tile when the hub has no usable quota window yet.
    static func tiles(view: ReportView, report: UsageReport?, hidden: Set<String>) -> [AgentTile] {
        let summaries = VendorQuotaSummary.summaries(rows: view.rows)
        let currentAccounts = (report?.accountObservations ?? []).filter(\.isCurrent)
        // A failed first balance read has no discovered descriptor yet, so view.billing can omit it.
        let billingReadings = report?.billing ?? view.billing
        let vendors = VendorMark.merged(summaries.map(\.vendor) + billingReadings.map(\.vendor)
            + currentAccounts.map(\.account.provider).sorted())
        let tiles = vendors.map { vendor in
            let key = VendorMark.key(vendor)
            let summary = summaries.first { $0.markKey == key }
            let billings = billingReadings.filter { VendorMark.key($0.vendor) == key }
            var seen = Set<String>()
            let accounts = (currentAccounts.filter { VendorMark.key($0.account.provider) == key }
                + (summary?.rows.compactMap(\.account) ?? []))
                .filter { seen.insert($0.id).inserted }
            let text = billings.first?.balances.first.map { amount($0.total, currency: $0.currency) }
            return AgentTile(id: key, vendor: vendor, usedPct: summary?.usedPct,
                             level: summary?.level ?? billings.compactMap { view.level(of: $0) }.first,
                             balance: text, rows: summary?.rows ?? [], billings: billings, accounts: accounts,
                             resetCredits: accounts.compactMap(\.resetCredits).first
                                ?? (key == "ChatGPT" ? report?.codexResetCredits : nil))
        }
        let rank = { (tile: AgentTile) in order.firstIndex(of: tile.id) ?? order.count }
        return tiles.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .filter { !hidden.contains($0.id) }
    }

    static func amount(_ value: Decimal, currency: String) -> String {
        if currency == "credits" {
            return value.formatted(.number.precision(.fractionLength(0...2))) + L10n.text(" 积分", " credits")
        }
        return MoneyFormat.amount(value, currency: currency)
    }

    /// Keep every balance and wallet, with stable identities even when their labels are the same.
    var amounts: [(id: String, label: String, value: String)] {
        var lines: [(String, String, String)] = []
        for billing in billings {
            for balance in billing.balances {
                let id = billing.id + ":" + balance.id
                lines.append((id, L10n.text("余额", "Balance"), Self.amount(balance.total, currency: balance.currency)))
                if balance.granted != 0 || balance.toppedUp != 0 {
                    lines.append((id + ":granted", L10n.text("赠送余额", "Granted balance"), Self.amount(balance.granted, currency: balance.currency)))
                    lines.append((id + ":toppedUp", L10n.text("充值余额", "Topped-up balance"), Self.amount(balance.toppedUp, currency: balance.currency)))
                }
            }
        }
        for account in accounts {
            for wallet in account.wallets ?? [] {
                let id = account.id + ":" + wallet.id
                let value: Decimal?
                let label: String
                switch wallet.kind {
                case .monthlySpend:
                    value = wallet.used
                    label = L10n.text("本月 API 花费", "API spend this month")
                case .prepaid:
                    value = wallet.balance
                    label = L10n.text("API 余额", "API balance")
                case .onDemand:
                    // An on-demand wallet reports used and limit; it need not have a balance.
                    for (key, label, value) in [("used", L10n.text("按需已用", "On-demand used"), wallet.used),
                                                ("limit", L10n.text("按需上限", "On-demand limit"), wallet.limit)] {
                        if let value { lines.append((id + ":" + key, label, Self.amount(value, currency: wallet.currency))) }
                    }
                    continue
                }
                if let value { lines.append((id, label, Self.amount(value, currency: wallet.currency))) }
            }
        }
        if let resetCredits {
            lines.append(("resets", L10n.text("可用额度重置", "Available resets"), "\(resetCredits.availableCount)"))
        }
        return lines
    }

    var sourceDetails: [String] {
        var seen = Set<String>()
        return accounts.compactMap(\.sourceInfo).filter { seen.insert($0).inserted }
    }

    var issues: [String] {
        var seen = Set<String>()
        return (billings.compactMap { $0.readingIssue?.reason ?? $0.notice }
            + accounts.compactMap { $0.readingIssue?.reason ?? $0.quotaNotice })
            .filter { seen.insert($0).inserted }
    }

    var updatedAt: Date? {
        (rows.compactMap(\.assessment.observedAt) + billings.filter { !$0.balances.isEmpty }.compactMap(\.updatedAt)
            + accounts.filter { $0.readingIssue == nil }.map(\.observedAt)
            + accounts.flatMap { ($0.wallets ?? []).compactMap(\.observedAt) }).max()
    }

    /// AGY's five windows belong to three model groups, so keep the periods beside each other.
    var quotaGroups: [(name: String, rows: [AgentRow])] {
        var names: [String] = []
        var grouped: [String: [AgentRow]] = [:]
        for row in rows {
            let name = row.agent.name.components(separatedBy: " · ").first ?? row.agent.name
            if grouped[name] == nil { names.append(name) }
            grouped[name, default: []].append(row)
        }
        return names.map { ($0, grouped[$0] ?? []) }
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
        let compact = chosen.id == "Antigravity"
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tiles) { tile in
                            tileView(tile, selected: tile.id == chosen.id, compact: compact)
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

    private func tileView(_ tile: AgentTile, selected: Bool, compact: Bool) -> some View {
        Button {
            selection = tile.id
        } label: {
            VStack(spacing: 4) {
                AgentRingMark(vendor: tile.vendor, usedPct: tile.usedPct, level: tile.level, size: compact ? 30 : 34)
                Text(tile.figure)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tile.usedPct == nil && tile.balance == nil ? AgentPalette.secondary : AgentPalette.color(tile.level))
                    .lineLimit(1)
            }
            .frame(width: 62, height: compact ? 48 : 58)
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
struct AgentDetailView: View {
    let tile: AgentTile
    let store: UsageStore
    let now: Date
    let isRequesting: Bool
    let refresh: () -> Void

    private var isAntigravity: Bool { tile.id == "Antigravity" }

    var body: some View {
        VStack(alignment: .leading, spacing: isAntigravity ? 5 : 7) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 7) {
                    if isAntigravity {
                        VStack(spacing: 5) {
                            ForEach(tile.quotaGroups, id: \.name) { group in
                                HStack(spacing: 12) {
                                    Text(group.name == "Claude and GPT models" ? "Claude / GPT"
                                         : group.name == "Gemini Models" ? "Gemini" : group.name)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .frame(width: 100, alignment: .leading)
                                        .help(group.name)
                                    ForEach(group.rows) { row in
                                        quotaValue(row, showsPeriod: true)
                                            .frame(maxWidth: .infinity)
                                            .accessibilityElement(children: .combine)
                                            .accessibilityLabel(row.agent.name)
                                    }
                                    if group.rows.count == 1 {
                                        Color.clear.frame(maxWidth: .infinity)
                                    }
                                }
                                .frame(height: 14)
                            }
                        }
                    } else {
                        ForEach(tile.rows) { row in windowLine(row) }
                    }
                    ForEach(tile.amounts, id: \.id) { amountLine($0.label, $0.value) }
                    ForEach(tile.sourceDetails, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(AgentPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(tile.issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(AgentPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
            if isAntigravity {
                Text(L10n.text("\(tile.quotaGroups.count) 组 · \(tile.rows.count) 项", "\(tile.quotaGroups.count) groups · \(tile.rows.count) windows"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(AgentPalette.secondary)
            }
            if let plan = tile.accounts.compactMap(\.planLabel).first ?? store.view.subscriptions[tile.vendor] {
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
        HStack(spacing: 10) {
            Text(row.agent.shortName)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
                .help(row.agent.name)
            quotaValue(row)
        }
        .frame(height: 14)
    }

    private func quotaValue(_ row: AgentRow, showsPeriod: Bool = false) -> some View {
        let used = row.assessment.showsLevel ? row.usedPct : nil
        let color = AgentPalette.color(row.level)
        let period = WindowNames.Period(seconds: store.report?.snapshot(for: row.id)?.windowDuration)?.shortName
        return HStack(spacing: showsPeriod ? 5 : 10) {
            if showsPeriod {
                Text(period ?? row.agent.shortName)
                    .font(.system(size: 10))
                    .foregroundStyle(AgentPalette.secondary)
                    .fixedSize()
            }
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
            Text(used.map { showsPeriod ? $0.formatted(.number.precision(.fractionLength(0...1))) + "%"
                : "\(Int($0.rounded()))%" } ?? "–")
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
        .help(row.agent.name + (row.resetAt.map { "\n" + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
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
                .textSelection(.enabled)
        }
        .frame(minHeight: 14)
    }

    /// How long ago the vendor was last read, from its own readings.
    private var updated: String? {
        guard let last = tile.updatedAt else { return nil }
        if now.timeIntervalSince(last) < 60 { return L10n.text("刚刚", "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: L10n.text("zh_CN", "en_US"))
        return formatter.localizedString(for: last, relativeTo: now)
    }
}
