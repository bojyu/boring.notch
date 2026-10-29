//
//  ServerMonitor.swift
//  boringNotch
//
//  Keeps the Beszel hub's servers fresh while the Servers tab is on screen, and reads nothing otherwise.
//

import Defaults
import Foundation
import Observation

@MainActor
@Observable
final class ServerMonitor {
    static let shared = ServerMonitor()

    private(set) var servers: [BeszelServer] = []
    private(set) var lastError: String?
    private(set) var lastRead: Date?
    private(set) var isReading = false

    /// Agents report about once a minute, so a read every 20 seconds keeps within one report of the hub.
    static let interval: Duration = .seconds(20)

    @ObservationIgnored private var client: BeszelClient?
    @ObservationIgnored private var clientKey: String?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {}

    var hasCredentials: Bool {
        let user = Defaults[.serversUser]
        return !user.isEmpty && ServerCredentialStore.password(for: user) != nil
    }

    func attach() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    /// Forgets the client, for a new address or account, and reads again when the tab is showing.
    func restart() {
        client = nil
        clientKey = nil
        servers = []
        lastError = nil
        lastRead = nil
        if viewers > 0 { Task { await read() } }
    }

    func read() async {
        guard !isReading else { return }
        guard let client = currentClient() else {
            lastError = hasCredentials ? BeszelError.badAddress.localizedDescription : nil
            return
        }
        isReading = true
        defer { isReading = false }
        do {
            servers = try await client.servers()
            lastError = nil
            lastRead = Date()
        } catch {
            // The last servers stay on screen; the error says why they stopped updating.
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func currentClient() -> BeszelClient? {
        let user = Defaults[.serversUser]
        let address = Defaults[.serversHubURL].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, let base = URL(string: address), base.scheme?.hasPrefix("http") == true else { return nil }
        let key = address + "|" + user
        if let client, clientKey == key { return client }
        let client = BeszelClient(base: base, user: user) { ServerCredentialStore.password(for: user) }
        self.client = client
        clientKey = key
        return client
    }
}
