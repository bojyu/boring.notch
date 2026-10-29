//
//  BeszelClient.swift
//  boringNotch
//
//  Reads the servers a Beszel hub watches, through its PocketBase API.
//

import AgentHUDCore
import Foundation

/// One server as the hub last heard from its agent.
struct BeszelServer: Identifiable, Equatable {
    enum Status: String { case up, down, paused, pending }

    let id: String
    let name: String
    let host: String
    let status: Status
    let cpu: Double?
    let memory: Double?
    let disk: Double?
    let diskName: String?
    /// Other filesystems' use, by name.
    let extraDisks: [(name: String, pct: Double)]
    let gpu: Double?
    let temperature: Double?
    /// Bytes per second, in and out together.
    let bandwidth: Double?
    let load: [Double]
    let threads: Int?
    let uptime: TimeInterval?
    let agentVersion: String?
    /// [total, failed] systemd services.
    let services: [Int]
    /// [total, security] package updates.
    let updates: [Int]
    let updated: Date?

    /// The busiest of CPU, memory and disk: what the tile's colour stands for.
    var worstPct: Double? { [cpu, memory, disk].compactMap { $0 }.max() }

    static func == (a: BeszelServer, b: BeszelServer) -> Bool {
        a.id == b.id && a.status == b.status && a.cpu == b.cpu && a.memory == b.memory && a.disk == b.disk
            && a.bandwidth == b.bandwidth && a.updated == b.updated && a.name == b.name
    }
}

enum BeszelError: LocalizedError {
    case badAddress
    case noCredentials
    case wrongCredentials
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badAddress: L10n.text("地址无效", "Invalid address")
        case .noCredentials: L10n.text("还没填账号密码", "No account yet")
        case .wrongCredentials: L10n.text("邮箱或密码不对", "Wrong e-mail or password")
        case .http(let code): "HTTP \(code)"
        }
    }
}

actor BeszelClient {
    private let base: URL
    private let user: String
    private let password: () -> String?
    private var token: String?

    init(base: URL, user: String, password: @escaping @Sendable () -> String?) {
        self.base = base
        self.user = user
        self.password = password
    }

    /// Every server the account can see, by name; signs in again once when the token has lapsed.
    func servers() async throws -> [BeszelServer] {
        if token == nil { try await signIn() }
        do {
            return try await listServers()
        } catch BeszelError.http(let code) where code == 401 || code == 403 {
            token = nil
            try await signIn()
            return try await listServers()
        }
    }

    /// Signs in as a hub user, or as a PocketBase superuser when the account is one.
    func signIn() async throws {
        guard let password = password(), !user.isEmpty else { throw BeszelError.noCredentials }
        var lastError: Error = BeszelError.wrongCredentials
        for collection in ["users", "_superusers"] {
            var request = URLRequest(url: base.appending(path: "api/collections/\(collection)/auth-with-password"),
                                     timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["identity": user, "password": password])
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = object["token"] as? String {
                self.token = token
                return
            }
            lastError = code == 400 || code == 401 || code == 403 || code == 404 ? BeszelError.wrongCredentials : BeszelError.http(code)
        }
        throw lastError
    }

    private func listServers() async throws -> [BeszelServer] {
        var components = URLComponents(url: base.appending(path: "api/collections/systems/records"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "perPage", value: "200"), URLQueryItem(name: "sort", value: "name")]
        guard let url = components?.url else { throw BeszelError.badAddress }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw BeszelError.http(code) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["items"] as? [[String: Any]] ?? []).compactMap(Self.server)
    }

    static func server(_ record: [String: Any]) -> BeszelServer? {
        guard let id = record["id"] as? String else { return nil }
        let info = record["info"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? {
            guard let value = info[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        func integers(_ key: String) -> [Int] { (info[key] as? [NSNumber])?.map(\.intValue) ?? [] }
        let extra = (info["efs"] as? [String: NSNumber] ?? [:])
            .map { (name: $0.key, pct: $0.value.doubleValue) }
            .sorted { $0.name < $1.name }
        // Older agents report megabytes per second in `b`; newer ones bytes per second in `bb`.
        let bandwidth = number("bb") ?? number("b").map { $0 * 1_048_576 }
        return BeszelServer(
            id: id,
            name: record["name"] as? String ?? id,
            host: record["host"] as? String ?? "",
            status: BeszelServer.Status(rawValue: record["status"] as? String ?? "") ?? .pending,
            cpu: number("cpu"), memory: number("mp"), disk: number("dp"),
            diskName: info["rdn"] as? String,
            extraDisks: extra,
            gpu: number("g"), temperature: number("dt"),
            bandwidth: bandwidth,
            load: (info["la"] as? [NSNumber])?.map(\.doubleValue) ?? [],
            threads: number("t").map(Int.init),
            uptime: number("u"),
            agentVersion: info["v"] as? String,
            services: integers("sv"), updates: integers("pu"),
            updated: (record["updated"] as? String).flatMap(Self.date))
    }

    private static func date(_ text: String) -> Date? {
        // PocketBase writes "2026-10-29 05:12:03.123Z".
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSX", "yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd'T'HH:mm:ss.SSSX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
