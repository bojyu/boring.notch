import AgentHUDCore
import AppKit
import SwiftUI
import XCTest
@testable import boringNotch

final class AgentQuotaMappingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_217_900)

    private func tiles(_ report: UsageReport, hidden: Set<String> = []) -> [AgentTile] {
        let view = ReportView(report: report, agents: report.discoveredAgents, settings: Settings(), now: now)
        return AgentTile.tiles(view: view, report: report, hidden: hidden)
    }

    private func account(_ vendor: String, user: String = "fixture") -> ProviderAccount {
        ProviderAccount.identified(provider: vendor, user: user, workspace: nil)!
    }

    func testEveryHubVendorAndEveryWindowIsKept() {
        let windows = [("Claude", ["claude-session", "claude-weekly", "claude-cloud"]),
                       ("Codex", ["codex", "codex:secondary"]),
                       ("Antigravity", ["antigravity:gemini-5h", "antigravity:claude-7d"]),
                       ("Muse", ["seven-day"]), ("Notion", ["rolling", "monthly", "credits"]),
                       ("Anthropic API", ["balance"])]
        let agents = windows.flatMap { vendor, keys in
            keys.map { key in AgentDescriptor(id: vendor + "/" + key, vendor: vendor, model: key, source: "fixture", enabled: true) }
        }
        let billing = ["DeepSeek", "OpenRouter", "Kie"].map {
            APIBilling(vendor: $0, balances: [.init(currency: "credits", total: 10, granted: 0, toppedUp: 0)],
                       isAvailable: true, updatedAt: now, notice: nil)
        }
        let report = UsageReport(generatedAt: now, snapshots: agents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 80, updatedAt: now)
        }, sessions: [], discoveredAgents: agents, billing: billing)
        let result = tiles(report)
        XCTAssertEqual(result.map(\.id), ["Claude", "ChatGPT", "Antigravity", "Muse", "Notion", "Anthropic API", "DeepSeek", "OpenRouter", "Kie"])
        XCTAssertEqual(Set(result.flatMap(\.rows).map(\.id)), Set(agents.map(\.id)))
        XCTAssertEqual(result.first { $0.id == "Notion" }?.rows.count, 3)
    }

    func testBalanceDoesNotDisappearWhenItsVendorAlsoHasQuotaRows() throws {
        let agent = AgentDescriptor(id: "quota", vendor: "Claude", model: "quota", source: "fixture", enabled: true)
        let billing = APIBilling(vendor: "Claude", balances: [
            .init(currency: "CNY", total: Decimal(string: "110.5")!, granted: 10, toppedUp: Decimal(string: "100.5")!),
            .init(currency: "USD", total: 5, granted: 0, toppedUp: 5)
        ], isAvailable: true, updatedAt: now, notice: nil)
        let report = UsageReport(generatedAt: now, snapshots: [.init(agentId: "quota", remainingPct: 60, updatedAt: now)],
                                 sessions: [], discoveredAgents: [agent], billing: [billing])
        let tile = try XCTUnwrap(tiles(report).first)
        XCTAssertEqual(tile.usedPct, 40)
        XCTAssertEqual(tile.billings.count, 1)
        XCTAssertEqual(tile.amounts.count, 6, "both currencies and their granted/topped-up parts")
        XCTAssertEqual(Set(tile.amounts.map(\.id)).count, tile.amounts.count)
        XCTAssertTrue(tile.amounts.contains { $0.value.contains("100.50") })
    }

    func testAllAccountWalletsAreKeptOnceIncludingZeroAndOnDemandLimits() throws {
        let first = account("Claude")
        let second = account("Claude", user: "second")
        let observations = [
            AccountObservation(account: first, observedAt: now, wallets: [
                .init(kind: .monthlySpend, used: 0), .init(kind: .onDemand, used: 12, limit: 50)
            ]),
            AccountObservation(account: second, observedAt: now, wallets: [.init(kind: .prepaid, balance: 25)])
        ]
        let agents = ["session", "weekly"].map { key in
            AgentDescriptor(id: first.windowID(key), vendor: "Claude", model: key, source: "fixture", enabled: true, account: first)
        }
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents,
                                 accounts: ["Claude": observations])
        let tile = try XCTUnwrap(tiles(report).first)
        XCTAssertEqual(tile.accounts.count, 2)
        XCTAssertEqual(tile.amounts.count, 4, "wallets are not duplicated for each quota window")
        XCTAssertTrue(tile.amounts.contains { $0.value.contains("0.00") })
        XCTAssertTrue(tile.amounts.contains { $0.value.contains("50.00") })
        XCTAssertEqual(Set(tile.amounts.map(\.id)).count, tile.amounts.count)
    }

    func testFirstFailedBalanceReadStillShowsVendorAndIssue() throws {
        let billing = APIBilling(vendor: "Kie", balances: [], isAvailable: nil, updatedAt: nil,
                                 notice: "Sign in again", readingIssue: .readFailed("Sign in again"))
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], billing: [billing])
        let tile = try XCTUnwrap(tiles(report).first)
        XCTAssertEqual(tile.id, "Kie")
        XCTAssertEqual(tile.issues, ["Sign in again"])
        XCTAssertNil(tile.balance)
        XCTAssertTrue(tile.amounts.isEmpty, "an unknown balance is not zero")
        XCTAssertTrue(tiles(report, hidden: ["Kie"]).isEmpty)
    }

    func testAccountDetailsAndZeroResetCountSurviveWithoutWindows() throws {
        let observation = AccountObservation(account: account("Codex"), plan: "pro", observedAt: now,
                                             readingIssue: .readFailed("Expired"),
                                             resetCredits: .init(availableCount: 0, credits: nil), sourceInfo: "Extra allowance")
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], accounts: ["Codex": [observation]])
        let tile = try XCTUnwrap(tiles(report).first)
        XCTAssertEqual(tile.id, "ChatGPT")
        XCTAssertEqual(tile.sourceDetails, ["Extra allowance"])
        XCTAssertEqual(tile.issues, ["Expired"])
        XCTAssertEqual(tile.amounts.first?.value, "0")
        XCTAssertNil(tile.updatedAt, "a failed read without a value is not a successful update")
    }

    func testCreditsAreFormattedAsUnitsRatherThanCurrency() {
        let text = AgentTile.amount(854, currency: "credits")
        XCTAssertTrue(text.contains("854"))
        XCTAssertFalse(text.contains("$"))
        XCTAssertFalse(text.contains("¥"))
        XCTAssertFalse(text.contains("CREDITS"))
    }

    @MainActor
    func testAntigravityKeepsAllFiveWindowsInThreeGroups() throws {
        let buckets: [(String, String, String, Double, TimeInterval)] = [
            ("gemini-weekly", "Gemini Models", "Weekly Limit Remaining", 2.7, 604800),
            ("gemini-5h", "Gemini Models", "Five Hour Limit Remaining", 0, 18000),
            ("3p-weekly", "Claude and GPT models", "Weekly Limit Remaining", 62.8, 604800),
            ("3p-5h", "Claude and GPT models", "Five Hour Limit Remaining", 0, 18000),
            ("gemini-argon-wtu-weekly", "Gemini 4 Argon", "Gemini 4 Argon Weekly Limit", 89.7, 604800)
        ]
        let agents = buckets.map { key, group, name, _, _ in
            AgentDescriptor(id: "antigravity:" + key, vendor: "Antigravity", model: group + " · " + name,
                            source: "fixture", enabled: true, allModels: false)
        }
        let report = UsageReport(generatedAt: now, snapshots: zip(agents, buckets).map { agent, bucket in
            UsageSnapshot(agentId: agent.id, remainingPct: 100 - bucket.3, resetAt: now.addingTimeInterval(bucket.4),
                          windowDuration: bucket.4, updatedAt: now)
        }, sessions: [], discoveredAgents: agents)
        let tile = try XCTUnwrap(tiles(report).first)
        XCTAssertEqual(tile.quotaGroups.map(\.name), ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"])
        XCTAssertEqual(tile.quotaGroups.map { $0.rows.count }, [2, 2, 1])
        XCTAssertEqual(Set(tile.quotaGroups.flatMap(\.rows).map(\.id)), Set(agents.map(\.id)))

        let suite = "AgentQuotaMappingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        let date = now
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { date })
        store.replace(report: report)
        // 190 minus the notch header (38), outer spacing/padding (20), and compact vendor strip (54).
        let hosting = NSHostingView(rootView: AgentDetailView(tile: tile, store: store, now: now, isRequesting: false, refresh: {})
            .frame(width: 566, height: 78)
            .background(.black)
            .environment(\.colorScheme, .dark))
        hosting.frame = CGRect(x: 0, y: 0, width: 566, height: 78)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        var warningPixels = 0
        for y in stride(from: bitmap.pixelsHigh * 2 / 3, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7, color.greenComponent > 0.5, color.blueComponent < 0.4 {
                    warningPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(warningPixels, 10, "Argon's last quota bar must be visible inside the default notch, without scrolling")
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/boring-notch-agy-preview.png"))
    }
}
