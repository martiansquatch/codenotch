import Foundation

/// Keeps every Codex profile's `auth.json` from ageing out.
///
/// Codenotch only reads that file, and Codex renews it only while someone uses
/// it. A second login (`~/.codex-personal`, say) left alone for ten days
/// expired, and its ring kept the last reading forever (#473). Asking
/// `codex app-server` for the account with `refreshToken: true` runs Codex's
/// own refresh flow — no model call, nothing counted against a limit — and
/// Codex writes the file itself, so no token is ever handled here.
///
/// Every profile is checked the same way and independently: a profile whose
/// renewal fails, or whose command will not start, is recorded and skipped,
/// and the next profile is still renewed.
///
/// The same no-retry-loop gate as `ClaudeTokenRefresher`: one attempt per
/// expiry value, judged on whether the expiry moved, never on an exit status.
@MainActor
final class CodexTokenRefresher {
    enum Outcome: Equatable {
        case refreshed(until: Date)
        case failed(String)
    }

    /// Starts the app server for one profile, asks it to refresh, and returns
    /// once `done` says the expiry moved or the timeout passed. Injected so
    /// the tests can stand in for the command per profile.
    typealias Launcher = @MainActor (_ cli: URL, _ profile: CodexProfile, _ timeout: TimeInterval,
                                     _ done: @escaping @MainActor () -> Bool) async throws -> Void

    /// Where Codex is usually installed. Not resolved through symlinks: the
    /// npm shim points into the package, and the shim is what a shell runs.
    nonisolated static func candidates(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin/codex",
         "/usr/local/bin/codex",
         (home as NSString).appendingPathComponent(".local/bin/codex"),
         (home as NSString).appendingPathComponent(".npm-global/bin/codex"),
         (home as NSString).appendingPathComponent(".volta/bin/codex"),
         (home as NSString).appendingPathComponent("Library/pnpm/codex")]
    }

    nonisolated static func standalone(candidates: [String] = candidates(),
                           fileManager: FileManager = .default) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private let profiles: [CodexProfile]
    private let cli: URL?
    private let margin: TimeInterval
    private let timeout: TimeInterval
    private let interval: TimeInterval
    private let readExpiry: @MainActor (CodexProfile) -> Date?
    private let launcher: Launcher

    private var timer: Timer?
    private var isRunning = false
    /// Keyed by profile id. The expiry an attempt was already spent on.
    private var attemptedFor: [String: Date] = [:]
    /// Keyed by profile id. What the last attempt for that profile came to.
    private(set) var outcomes: [String: Outcome] = [:]

    init(profiles: [CodexProfile],
         cli: URL? = CodexTokenRefresher.standalone(),
         margin: TimeInterval = 24 * 60 * 60,
         timeout: TimeInterval = 30,
         interval: TimeInterval = 30 * 60,
         readExpiry: @escaping @MainActor (CodexProfile) -> Date? = CodexTokenRefresher.expiry(of:),
         launcher: Launcher? = nil) {
        self.profiles = profiles
        self.cli = cli
        self.margin = margin
        self.timeout = timeout
        self.interval = interval
        self.readExpiry = readExpiry
        self.launcher = launcher ?? { cli, profile, timeout, done in
            try await CodexTokenRefresher.run(cli, profile: profile, timeout: timeout, done: done)
        }
    }

    func start() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        Task { await renewDue() }
    }

    /// When the access token in a profile's `auth.json` stops being accepted.
    /// Nil when there is no file, or the token carries no expiry — and then
    /// nothing is launched, the same as `ClaudeTokenRefresher` with no reading.
    nonisolated static func expiry(of profile: CodexProfile) -> Date? {
        guard let data = try? Data(contentsOf: profile.authURL) else { return nil }
        return expiry(inAuth: data)
    }

    nonisolated static func expiry(inAuth data: Data) -> Date? {
        struct Auth: Decodable {
            struct Tokens: Decodable { let access_token: String }
            let tokens: Tokens
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
              let exp = CodexCredentials.claims(inJWT: auth.tokens.access_token)?["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    func renewDue(now: Date = Date()) async {
        guard !isRunning, let cli else { return }
        isRunning = true
        defer { isRunning = false }

        for profile in profiles {
            let key = profile.id
            let current = readExpiry(profile)
            guard ClaudeTokenRefresher.shouldRenew(expiry: current, now: now, margin: margin,
                                                   attemptedFor: attemptedFor[key],
                                                   lastAttempt: nil, cooldown: 0),
                  let current
            else { continue }
            attemptedFor[key] = current

            Log.usage.notice("codex token for \(profile.displayPath, privacy: .public) expires \(current, privacy: .public); renewing")
            let readExpiry = self.readExpiry
            do {
                try await launcher(cli, profile, timeout) {
                    (readExpiry(profile) ?? current) > current
                }
            } catch {
                // Recorded and passed over: the next profile is still renewed.
                outcomes[key] = .failed("Couldn't run `codex` to renew \(profile.displayName)'s saved login.")
                Log.usage.error("codex token renewal for \(profile.displayPath, privacy: .public) could not start: \(String(describing: error), privacy: .public)")
                continue
            }
            if let after = readExpiry(profile), after > current {
                outcomes[key] = .refreshed(until: after)
                Log.usage.notice("codex token for \(profile.displayPath, privacy: .public) renewed, now expires \(after, privacy: .public)")
            } else {
                outcomes[key] = .failed("\(profile.displayName) usage needs its sign-in renewed — run `\(profile.signInCommand)`.")
                Log.usage.error("codex token renewal for \(profile.displayPath, privacy: .public) did not move the expiry")
            }
        }
    }

    // MARK: - Running it

    /// Verified against the schema `codex app-server generate-json-schema`
    /// prints (codex-cli 0.166.0): `initialize` needs `clientInfo` with a
    /// name and version, and `account/read` takes `refreshToken`.
    static let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codenotch","version":"0"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"account/read","params":{"refreshToken":true}}"#,
    ]

    /// The environment the app server runs with: the profile's own
    /// `CODEX_HOME`, so it reads and writes that profile's `auth.json`.
    static func environment(base: [String: String], profile: CodexProfile) -> [String: String] {
        var environment = base
        environment["CODEX_HOME"] = profile.configDirectory.path
        return environment
    }

    /// Starts the app server for one profile, asks for the refresh, and waits
    /// until `done` says the file moved or the timeout passes. The process is
    /// always stopped before returning.
    static func run(_ cli: URL, profile: CodexProfile, timeout: TimeInterval,
                    done: @MainActor () -> Bool) async throws {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["app-server"]
        process.environment = environment(base: ProcessInfo.processInfo.environment, profile: profile)
        if let scratch = try? ClaudeUsageCLI.scratchDirectory() {
            process.currentDirectoryURL = scratch
        }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let payload = requests.joined(separator: "\n") + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !done() {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                while process.isRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
    }
}
