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
///
/// A failure stays reported until it is actually resolved: either a renewal
/// here moves the expiry, or the profile's stored token is replaced (the user
/// ran the command, or Codex renewed it while in use). Renewal starts a day
/// before expiry, so after a failure the old token still works for hours — a
/// usage reading coming back proves nothing about whether it will be renewed,
/// and clearing on one hid the problem until the token died.
@MainActor
final class CodexTokenRefresher {
    enum Outcome: Equatable {
        case refreshed(until: Date)
        case failed(String)
        /// The token a failure was recorded against is no longer the one
        /// stored: it was renewed or signed in again outside Codenotch.
        case replaced(until: Date)
    }

    /// What identifies one stored sign-in: its expiry, and a digest of the
    /// access token so a replacement is noticed even if the expiry happened to
    /// match. The token itself is never kept. The same type Claude's sign-ins
    /// are judged by.
    typealias StoredToken = ClaudeTokenRefresher.StoredToken

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
    private let readToken: @MainActor (CodexProfile) -> StoredToken?
    private let launcher: Launcher

    private var timer: Timer?
    private var isRunning = false
    /// Keyed by profile id. The expiry an attempt was already spent on.
    private var attemptedFor: [String: Date] = [:]
    /// Keyed by profile id. The stored token a failure was reported against.
    /// The failure stands until this profile is renewed here or holds a
    /// different token; nothing else clears it.
    private var failedOn: [String: StoredToken] = [:]
    /// Keyed by profile id. What the last attempt for that profile came to.
    private(set) var outcomes: [String: Outcome] = [:]
    /// Told each time a profile's renewal fails, with that profile's provider
    /// id and the command that renews it by hand. AppDelegate passes this to
    /// `UsageStore.reportRenewalFailed`, the same warning a failed Claude
    /// renewal raises in Settings.
    var onFailure: (@MainActor (_ providerID: String, _ command: String) -> Void)?
    /// Told when a profile that failed is fine again: a renewal here moved its
    /// expiry, or its `auth.json` now holds a different token. The only thing
    /// that should take the warning `onFailure` raised away.
    var onRecovery: (@MainActor (_ providerID: String) -> Void)?

    init(profiles: [CodexProfile],
         cli: URL? = CodexTokenRefresher.standalone(),
         margin: TimeInterval = 24 * 60 * 60,
         timeout: TimeInterval = 30,
         interval: TimeInterval = 30 * 60,
         readExpiry: (@MainActor (CodexProfile) -> Date?)? = nil,
         readToken: (@MainActor (CodexProfile) -> StoredToken?)? = nil,
         launcher: Launcher? = nil) {
        self.profiles = profiles
        self.cli = cli
        self.margin = margin
        self.timeout = timeout
        self.interval = interval
        // `readExpiry` is the tests' shorthand for a token known only by its
        // expiry; left out, the real `auth.json` is read.
        if let readToken {
            self.readToken = readToken
        } else if let readExpiry {
            self.readToken = { readExpiry($0).map { StoredToken(expiry: $0, fingerprint: nil) } }
        } else {
            self.readToken = CodexTokenRefresher.token(of:)
        }
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
        token(of: profile)?.expiry
    }

    nonisolated static func expiry(inAuth data: Data) -> Date? {
        token(inAuth: data)?.expiry
    }

    /// The stored sign-in in a profile's `auth.json`, read in one go so the
    /// expiry and the fingerprint always describe the same token.
    nonisolated static func token(of profile: CodexProfile) -> StoredToken? {
        guard let data = try? Data(contentsOf: profile.authURL) else { return nil }
        return token(inAuth: data)
    }

    nonisolated static func token(inAuth data: Data) -> StoredToken? {
        struct Auth: Decodable {
            struct Tokens: Decodable { let access_token: String }
            let tokens: Tokens
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
              let exp = CodexCredentials.claims(inJWT: auth.tokens.access_token)?["exp"] as? Double
        else { return nil }
        return StoredToken(expiry: Date(timeIntervalSince1970: exp),
                           accessToken: auth.tokens.access_token)
    }

    func renewDue(now: Date = Date()) async {
        guard !isRunning, let cli else { return }
        isRunning = true
        defer { isRunning = false }

        for profile in profiles {
            let key = profile.id
            let token = readToken(profile)
            noticeReplacement(of: profile, token: token)
            let current = token?.expiry
            guard ClaudeTokenRefresher.shouldRenew(expiry: current, now: now, margin: margin,
                                                   attemptedFor: attemptedFor[key],
                                                   lastAttempt: nil, cooldown: 0),
                  let current
            else { continue }
            attemptedFor[key] = current

            Log.usage.notice("codex token for \(profile.displayPath, privacy: .public) expires \(current, privacy: .public); renewing")
            let readToken = self.readToken
            do {
                try await launcher(cli, profile, timeout) {
                    (readToken(profile)?.expiry ?? current) > current
                }
            } catch {
                // Recorded and passed over: the next profile is still renewed.
                fail(profile, on: token, "Couldn't run `codex` to renew \(profile.displayName)'s saved login.")
                Log.usage.error("codex token renewal for \(profile.displayPath, privacy: .public) could not start: \(String(describing: error), privacy: .public)")
                continue
            }
            if let after = readToken(profile)?.expiry, after > current {
                outcomes[key] = .refreshed(until: after)
                Log.usage.notice("codex token for \(profile.displayPath, privacy: .public) renewed, now expires \(after, privacy: .public)")
                recover(profile)
            } else {
                fail(profile, on: token, "\(profile.displayName) usage needs its sign-in renewed — run `\(profile.renewalCommand)` once in a terminal.")
                Log.usage.error("codex token renewal for \(profile.displayPath, privacy: .public) did not move the expiry")
            }
        }
    }

    /// Re-reads one profile's stored token and clears its failure if the
    /// token was replaced. One small file read; nothing is launched. Called
    /// when a usage reading comes back for a profile with a failure standing,
    /// so a fix made by hand is noticed within a polling pass rather than at
    /// the next renewal tick.
    func noticeReplacedToken(providerID: String) {
        guard let profile = profiles.first(where: { $0.id == providerID }) else { return }
        noticeReplacement(of: profile, token: readToken(profile))
    }

    /// A failure is about one token. Once `auth.json` holds a different one,
    /// the failure no longer describes anything — and the one-attempt memory
    /// is dropped with it, so the new token is renewed in its turn like any
    /// other. Nothing read (no file, no expiry) is not a replacement.
    private func noticeReplacement(of profile: CodexProfile, token: StoredToken?) {
        guard let failed = failedOn[profile.id], let token, token != failed else { return }
        attemptedFor[profile.id] = nil
        outcomes[profile.id] = .replaced(until: token.expiry)
        Log.usage.notice("codex token for \(profile.displayPath, privacy: .public) was replaced, now expires \(token.expiry, privacy: .public)")
        recover(profile)
    }

    private func fail(_ profile: CodexProfile, on token: StoredToken?, _ message: String) {
        outcomes[profile.id] = .failed(message)
        if let token { failedOn[profile.id] = token }
        onFailure?(profile.id, profile.renewalCommand)
    }

    private func recover(_ profile: CodexProfile) {
        failedOn[profile.id] = nil
        onRecovery?(profile.id)
    }

    /// Shows this refresher's failures as Settings warnings in `store`, held
    /// until this refresher says the profile recovered. A usage reading coming
    /// back only prompts a re-check of the stored token; on its own it clears
    /// nothing. `store` is a getter so AppDelegate can pass its optional one.
    func warn(through store: @escaping @MainActor () -> UsageStore?) {
        onFailure = { [weak self] providerID, command in
            store()?.reportRenewalFailed(providerID: providerID, command: command,
                                         recheck: { [weak self] in
                                             self?.noticeReplacedToken(providerID: providerID)
                                         })
        }
        onRecovery = { providerID in
            store()?.reportRenewalRecovered(providerID: providerID)
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
