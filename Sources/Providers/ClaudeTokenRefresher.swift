import CryptoKit
import Foundation

/// Keeps the Claude OAuth token in the login keychain from ageing out.
///
/// Codenotch reads that item; only the standalone Claude Code command ever
/// writes it. On a Mac where Claude Code is used through the desktop app the
/// item is therefore written once and then rots — the desktop app renews its
/// own copy elsewhere — and eight hours later every usage reading stops, with
/// nothing the user can do from inside Codenotch. That is the hole this fills.
///
/// **How it renews, and why that is a compatibility mechanism rather than an
/// interface.** Running `claude -p` with an empty stdin makes the command go
/// through its whole start-up — which is where it checks the token's age and
/// renews it — and then exit non-zero with "Input must be provided…", because
/// no prompt ever arrives. Verified on a real machine: the keychain item's
/// modification date moves, the expiry advances by eight hours, no transcript
/// is written, no conversation is created, and the debug log shows no call to
/// the messages endpoint.
///
/// None of that is promised by anyone. A future release could stop renewing at
/// start-up, or stop rejecting an empty prompt. Both are handled by judging the
/// *outcome* instead of trusting the command: unless the expiry actually moved,
/// this reports failure and stops trying. And because it never supplies a
/// prompt, a version that started accepting empty input could not be talked
/// into answering one by accident — the failure mode is a wasted launch, never
/// an invented conversation.
///
/// A failure stays reported until it is actually resolved: a renewal here
/// moves the expiry, or the profile's stored token is replaced (the user ran
/// the command). Renewal runs in the last four minutes, so the token a failure
/// was recorded against can still answer a reading or two — and since it is
/// never launched for again, clearing the warning on such a reading left
/// nothing to raise it when that token died. The same rule as
/// `CodexTokenRefresher`, which tries a day ahead and so hit it first.
@MainActor
final class ClaudeTokenRefresher: ObservableObject {
    enum Outcome: Equatable {
        case idle
        case refreshed(until: Date)
        /// Ran, or could not be run, and the token is still going to expire.
        /// The string is what the user should be told.
        case failed(String)
        /// The token a failure was recorded against is no longer the one
        /// stored: it was renewed or signed in again outside Codenotch.
        case replaced(until: Date)
    }

    /// What identifies one stored sign-in: its expiry, and a digest of the
    /// access token so a replacement is noticed even if the expiry happened to
    /// match. The token itself is never kept. Shared with
    /// `CodexTokenRefresher`, which judges its sign-ins the same way.
    ///
    /// A nil fingerprint is a sign-in known only by its expiry; two of those
    /// differ only when the expiry does.
    struct StoredToken: Equatable, Sendable {
        let expiry: Date
        let fingerprint: String?

        init(expiry: Date, fingerprint: String?) {
            self.expiry = expiry
            self.fingerprint = fingerprint
        }

        /// Digests `accessToken` on the spot; only the digest is kept.
        init(expiry: Date, accessToken: String) {
            self.init(expiry: expiry, fingerprint: Self.fingerprint(of: accessToken))
        }

        /// SHA-256 of the token, hex. Enough to tell two tokens apart, and
        /// useless for anything else.
        static func fingerprint(of accessToken: String) -> String {
            SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// A started command: its pid, known synchronously so the session monitor
    /// can be told to ignore it before it can ever be scanned, and a way to
    /// wait for it.
    typealias Launcher = @MainActor (URL, TimeInterval) throws
        -> (pid: Int32, exit: () async -> Int32?)

    @Published private(set) var outcome: Outcome = .idle
    /// Set while the command runs. `ClaudeSessionMonitor.ignoredPIDs` reads
    /// this: the CLI registers a session file of its own for the second it
    /// lives, and it must never show up in the notch as work.
    private(set) var launchedPID: Int32?

    /// How close to expiry is close enough.
    ///
    /// **Must stay under Claude Code's own five minutes.** Its start-up renews
    /// the token only when `Date.now() + 300s >= expiresAt`; launching it any
    /// earlier than that is a no-op, which this would then correctly report as
    /// a failure and stop retrying. Four minutes leaves room for a slow start
    /// without crossing that line.
    private let margin: TimeInterval
    private let cooldown: TimeInterval
    private let timeout: TimeInterval
    private let interval: TimeInterval

    private let cli: URL?
    private let launcher: Launcher
    /// The profile directory the command is pointed at through
    /// `CLAUDE_CONFIG_DIR`. Nil for the default `~/.claude`, which must be
    /// renewed with that variable absent rather than set to its own path:
    /// Claude Code files the default token under a different keychain name
    /// than an explicitly named directory.
    let configDirectory: URL?
    /// The token as the usage provider last read it. Cheap: it is the value
    /// already in hand, so asking costs no keychain traffic and no prompt.
    private let token: @MainActor () async -> StoredToken?
    /// Drop the held copy and read the keychain again — the after-check.
    private let reload: @MainActor () async -> StoredToken?
    /// Look at what is stored now, for a failure standing when a reading comes
    /// back. Re-reads only when the stored item changed; see
    /// `ClaudeOAuthProvider.recheckStoredToken`.
    private let recheck: @MainActor () async -> StoredToken?

    private var timer: Timer?
    private var isRunning = false
    /// Exposed for the test that proves `isRunning` is claimed *before* the
    /// first `await` — not after, which is what would leave a window for two
    /// overlapping calls to both pass the guard.
    var isRunningForTesting: Bool { isRunning }
    private var lastAttempt: Date?
    /// The expiry a launch was already spent on. One attempt per token, which
    /// is what makes a failure stop instead of looping: a token that did not
    /// renew has the same expiry next tick, and is refused.
    private var attemptedFor: Date?
    /// The stored token a failure was reported against. The failure stands
    /// until this profile is renewed here or holds a different token; a
    /// reading coming back clears nothing.
    private var failedOn: StoredToken?
    /// Told each time a renewal fails. `warn(through:providerID:command:)`
    /// points it at `UsageStore.reportRenewalFailed`, which raises the
    /// Settings warning.
    var onFailure: (@MainActor () -> Void)?
    /// Told when a failure no longer stands: a renewal here moved the expiry,
    /// or the stored token is a different one. The only thing that should
    /// take the warning `onFailure` raised away.
    var onRecovery: (@MainActor () -> Void)?

    /// The tests' shorthand: a token known only by its expiry, with a reading
    /// re-checked by reloading. The app passes the provider's full sign-in.
    convenience init(
        expiry: @escaping @MainActor () async -> Date?,
        reload: @escaping @MainActor () async -> Date?,
        cli: URL? = ClaudeCLI.standalone(),
        margin: TimeInterval = 4 * 60,
        cooldown: TimeInterval = 10 * 60,
        timeout: TimeInterval = 30,
        interval: TimeInterval = 60,
        configDirectory: URL? = nil,
        launcher: Launcher? = nil
    ) {
        self.init(token: { await expiry().map { StoredToken(expiry: $0, fingerprint: nil) } },
                  reload: { await reload().map { StoredToken(expiry: $0, fingerprint: nil) } },
                  cli: cli, margin: margin, cooldown: cooldown, timeout: timeout,
                  interval: interval, configDirectory: configDirectory, launcher: launcher)
    }

    init(
        token: @escaping @MainActor () async -> StoredToken?,
        reload: @escaping @MainActor () async -> StoredToken?,
        recheck: (@MainActor () async -> StoredToken?)? = nil,
        cli: URL? = ClaudeCLI.standalone(),
        margin: TimeInterval = 4 * 60,
        cooldown: TimeInterval = 10 * 60,
        timeout: TimeInterval = 30,
        interval: TimeInterval = 60,
        configDirectory: URL? = nil,
        launcher: Launcher? = nil
    ) {
        self.token = token
        self.reload = reload
        self.recheck = recheck ?? reload
        self.cli = cli
        self.margin = margin
        self.cooldown = cooldown
        self.timeout = timeout
        self.interval = interval
        self.configDirectory = configDirectory
        // A profile other than `~/.claude` is renewed by naming its directory,
        // exactly as the shell alias that signed it in does.
        self.launcher = launcher ?? { cli, timeout in
            try ClaudeTokenRefresher.run(cli, timeout: timeout, configDirectory: configDirectory)
        }
    }

    /// One refresher per Claude profile, each renewing its own directory.
    ///
    /// #473: only the default profile used to be renewed, so a second login
    /// (`~/.claude-personal`, say) that sat unused for a few hours aged out and
    /// its ring stopped moving. Every profile now gets the same refresher with
    /// the same one-attempt gate; they share nothing, so a failure on one
    /// cannot hold back another.
    ///
    /// `launcher` is the seam the tests use to stand in for the command per
    /// profile; left nil, each refresher runs the real one.
    static func forEveryProfile(
        _ profiles: [ClaudeProfile],
        token: @escaping @MainActor (ClaudeProfile) async -> StoredToken?,
        reload: @escaping @MainActor (ClaudeProfile) async -> StoredToken?,
        recheck: (@MainActor (ClaudeProfile) async -> StoredToken?)? = nil,
        cli: URL? = ClaudeCLI.standalone(),
        launcher: ((ClaudeProfile) -> Launcher)? = nil
    ) -> [(profile: ClaudeProfile, refresher: ClaudeTokenRefresher)] {
        profiles.map { profile in
            let refresher = ClaudeTokenRefresher(
                token: { await token(profile) },
                reload: { await reload(profile) },
                recheck: recheck.map { recheck in { await recheck(profile) } },
                cli: cli,
                configDirectory: profile.slug == nil ? nil : profile.configDirectory,
                launcher: launcher?(profile)
            )
            return (profile, refresher)
        }
    }

    /// The tests' shorthand: every profile's token known only by its expiry.
    static func forEveryProfile(
        _ profiles: [ClaudeProfile],
        expiry: @escaping @MainActor (ClaudeProfile) async -> Date?,
        reload: @escaping @MainActor (ClaudeProfile) async -> Date?,
        cli: URL? = ClaudeCLI.standalone(),
        launcher: ((ClaudeProfile) -> Launcher)? = nil
    ) -> [(profile: ClaudeProfile, refresher: ClaudeTokenRefresher)] {
        forEveryProfile(profiles,
                        token: { await expiry($0).map { StoredToken(expiry: $0, fingerprint: nil) } },
                        reload: { await reload($0).map { StoredToken(expiry: $0, fingerprint: nil) } },
                        cli: cli, launcher: launcher)
    }

    /// Every pid any of these refreshers has running right now — what the
    /// Claude session monitors step over, whichever profile launched it.
    static func launchedPIDs(of refreshers: [ClaudeTokenRefresher]) -> Set<Int32> {
        Set(refreshers.compactMap(\.launchedPID))
    }

    func start() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        Task { await considerRenewing() }
    }

    // MARK: - The gate

    /// Whether a launch is worth making. Pure, so every branch is testable
    /// without a clock, a keychain or a subprocess.
    static func shouldRenew(
        expiry: Date?,
        now: Date,
        margin: TimeInterval,
        attemptedFor: Date?,
        lastAttempt: Date?,
        cooldown: TimeInterval
    ) -> Bool {
        // Nothing read yet: never launch on a guess.
        guard let expiry else { return false }
        // Plenty of time left. Also the case where launching would do nothing,
        // because the command's own gate has not opened either.
        guard expiry.timeIntervalSince(now) < margin else { return false }
        // Already spent an attempt on this exact token. This is the whole
        // no-retry-loop guarantee: a launch that failed to move the expiry
        // leaves the same value here next tick, and never runs again.
        guard expiry != attemptedFor else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < cooldown { return false }
        return true
    }

    func considerRenewing(now: Date = Date()) async {
        // Claimed here, synchronously, before anything is awaited — not after
        // deciding there is something to do. `shouldRenew` also happens to
        // block a second overlapping call in the common case (it shares
        // `attemptedFor` and the cooldown, both written moments from now), but
        // both of those depend on the two calls agreeing on roughly the same
        // token and the same `now`. `isRunning` does not: it is what makes "at
        // most one launch" true unconditionally, and it can only do that by
        // being set before the first `await` — set any later and a second
        // overlapping call reaches this same guard while `isRunning` is still
        // false, exactly as `token()` below is what it would be waiting on.
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; launchedPID = nil }

        let stored = await token()
        noticeReplacement(of: stored)
        guard Self.shouldRenew(expiry: stored?.expiry, now: now, margin: margin,
                               attemptedFor: attemptedFor, lastAttempt: lastAttempt,
                               cooldown: cooldown),
              let stored
        else { return }
        let current = stored.expiry

        lastAttempt = now
        attemptedFor = current

        let remaining = current.timeIntervalSince(now)
        guard let cli else {
            fail(on: stored,
                 "Claude's saved login is about to expire and the `claude` command "
               + "isn't installed to renew it. Run Claude Code once to sign in again.")
            return
        }
        Log.usage.notice("claude token expires in \(remaining, format: .fixed(precision: 0))s; renewing via \(cli.path, privacy: .public)")

        let status: Int32?
        do {
            let (pid, exit) = try launcher(cli, timeout)
            launchedPID = pid          // synchronously, before it can be scanned
            status = await exit()
        } catch {
            fail(on: stored, "Couldn't run `claude` to renew Claude's saved login.")
            Log.usage.error("token renewal could not start: \(String(describing: error), privacy: .public)")
            return
        }

        // Judged on the outcome, never on the exit status: refusing an empty
        // prompt is a *non-zero* exit and a successful renewal at the same time.
        let reloaded = await reload()
        guard let after = reloaded?.expiry, after > current else {
            // Against what is stored now, where the after-check read it: that
            // is what a later look will be compared with.
            fail(on: reloaded ?? stored,
                 "Claude usage needs its sign-in renewed — run `claude` once in a terminal.")
            Log.usage.error("token renewal ran (exit \(status ?? -1)) but the expiry did not move; still \(String(describing: reloaded?.expiry), privacy: .public)")
            return
        }
        outcome = .refreshed(until: after)
        Log.usage.notice("claude token renewed, now expires \(after, privacy: .public)")
        recover()
    }

    /// Looks at the stored token and clears a standing failure if it was
    /// replaced. Called when a usage reading comes back while a failure
    /// stands, so a fix made by hand is noticed within a polling pass rather
    /// than at the next tick. Reads nothing when no failure stands.
    func noticeReplacedToken() async {
        guard failedOn != nil else { return }
        noticeReplacement(of: await recheck())
    }

    /// A failure is about one token. Once a different one is stored, the
    /// failure no longer describes anything — and the one-attempt memory goes
    /// with it, so the new token is renewed in its turn like any other.
    /// Nothing read (no item, a refused or transient read) is not a
    /// replacement.
    private func noticeReplacement(of token: StoredToken?) {
        guard let failed = failedOn, let token, token != failed else { return }
        attemptedFor = nil
        outcome = .replaced(until: token.expiry)
        let whose = configDirectory?.path ?? "the default profile"
        Log.usage.notice("claude token for \(whose, privacy: .public) was replaced, now expires \(token.expiry, privacy: .public)")
        recover()
    }

    private func fail(on token: StoredToken?, _ message: String) {
        outcome = .failed(message)
        if let token { failedOn = token }
        onFailure?()
    }

    private func recover() {
        failedOn = nil
        onRecovery?()
    }

    /// Shows this profile's failures as a Settings warning in `store`, held
    /// until this refresher says the profile recovered. A usage reading
    /// coming back only prompts a look at the stored token; on its own it
    /// clears nothing. `store` is a getter so AppDelegate can pass its
    /// optional one.
    func warn(through store: @escaping @MainActor () -> UsageStore?,
              providerID: String, command: String) {
        onFailure = { [weak self] in
            store()?.reportRenewalFailed(providerID: providerID, command: command,
                                         recheck: { [weak self] in
                                             await self?.noticeReplacedToken()
                                         })
        }
        onRecovery = {
            store()?.reportRenewalRecovered(providerID: providerID)
        }
    }

    // MARK: - Running it

    /// Starts the command and hands back its pid plus a way to wait for it.
    ///
    /// `nullDevice` on stdin is the whole trick: the command gets an immediate
    /// end-of-input, so it starts up, renews, and refuses for want of a prompt.
    /// Output goes nowhere — there is nothing in it worth keeping, and a token
    /// could in principle be echoed into it.
    /// Contained the way `ClaudeUsageCLI` is (#227). Without these the run
    /// started every MCP server and hook the user had configured, from
    /// whatever directory the app was launched in — `/` from Finder — and
    /// macOS put their reads of Desktop, Documents, Downloads and network
    /// volumes to the user as Codenotch asking for access.
    static let arguments = ["-p", "--no-session-persistence", "--strict-mcp-config"]

    /// The environment the renewal runs with. Pure, so the one thing that
    /// differs between profiles — `CLAUDE_CONFIG_DIR` — is testable without
    /// launching anything.
    static func environment(base: [String: String], scratch: URL?,
                            configDirectory: URL?) -> [String: String] {
        var environment = base
        if let scratch { environment["PWD"] = scratch.path }
        // Nil for the default profile, which must not inherit a stray value
        // from wherever the app happened to be launched.
        if let configDirectory {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory.path
        } else {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        return environment
    }

    static func run(_ cli: URL, timeout: TimeInterval, configDirectory: URL? = nil) throws
        -> (pid: Int32, exit: () async -> Int32?) {
        let process = Process()
        process.executableURL = cli
        process.arguments = Self.arguments
        // The same fixed directory `/usage` runs from, never the app's own.
        let scratch = try? ClaudeUsageCLI.scratchDirectory()
        if let scratch { process.currentDirectoryURL = scratch }
        process.environment = environment(base: ProcessInfo.processInfo.environment,
                                          scratch: scratch,
                                          configDirectory: configDirectory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let wait: () async -> Int32? = {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !process.isRunning else {
                // Never left to linger: a renewal that hangs is exactly the
                // shape of the bug this app just had to fix elsewhere.
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    // Confirmed rather than assumed: every other process this
                    // app spawns is waited on after asking it to stop
                    // (`CodexBridge`, `AntigravityBridge`, both via the
                    // synchronous `waitUntilExit()`). That call would block
                    // this function's caller — MainActor, since `run` is
                    // isolated to it — so the same guarantee is reached by
                    // polling instead, at the cost of a few more lines for the
                    // one path that needs it.
                    while process.isRunning {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                return nil
            }
            return process.terminationStatus
        }
        return (process.processIdentifier, wait)
    }
}
