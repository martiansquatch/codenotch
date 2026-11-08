import XCTest
@testable import Codenotch

/// The warning that says a saved login has aged out.
///
/// It exists because the failure it reports is invisible everywhere else: an
/// expired token leaves the last reading on screen, still roughly true, and
/// nothing about the ring says the number stopped moving. That is how a frozen
/// reading went twelve hours without being noticed. So the warning is tied to
/// the credential, never to whether there is a number.
@MainActor
final class RenewalWarningTests: XCTestCase {
    private final class Provider: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName: String
        let glyph = ProviderGlyph.claude
        init(id: String = "claude", displayName: String = "Claude") {
            self.id = id
            self.displayName = displayName
        }
        /// Set to make the next fetch fail the way an aged-out token does.
        var tokenExpired = false

        func fetchSnapshot() async throws -> ProviderSnapshot {
            if tokenExpired { throw UsageProviderError.credentialExpired }
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "w", label: "W",
                                                          usedFraction: 0.4)])
        }

        func signOut() async {}
    }

    private func store(_ providers: Provider...) -> UsageStore {
        let name = "RenewalWarningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageStore(providers: providers, archive: UsageArchive(defaults: defaults))
    }

    private func text(_ store: UsageStore, _ id: String) -> String? {
        store.providerSummaries.first { $0.id == id }?.renewalWarning
    }

    private func warning(_ store: UsageStore) -> Bool {
        store.providerSummaries.first { $0.id == "claude" }?.needsSignInRenewal ?? false
    }

    // MARK: - Appearance

    func testNothingIsShownUntilARenewalActuallyFails() async {
        let store = store(Provider())
        await store.refresh()
        XCTAssertFalse(warning(store))
    }

    func testItAppearsWhenARenewalFails() {
        let store = store(Provider())
        store.reportRenewalFailed(providerID: "claude", command: "claude")
        XCTAssertTrue(warning(store))
    }

    // MARK: - Persistence behind a stale reading

    /// The regression this is really for. After the token ages out the fetch
    /// fails, but the remembered reading stays on screen and keeps its numbers
    /// — so anything that keyed the warning off "is there a reading" would hide
    /// it behind exactly the stale figure it is warning about.
    func testAStaleReadingDoesNotHideIt() async {
        let provider = Provider()
        let store = store(provider)
        await store.refresh()                       // a real reading, remembered
        XCTAssertEqual(store.snapshots.first?.windows.count, 1)

        provider.tokenExpired = true
        store.reportRenewalFailed(providerID: "claude", command: "claude")
        await store.refresh()

        XCTAssertTrue(store.snapshots.first?.hasReading == true,
                      "the old number is still on screen, which is the point")
        XCTAssertTrue(warning(store), "and the warning is still there behind it")
    }

    /// Repeated failures do not pile up or flap.
    func testReportingTwiceChangesNothing() {
        let store = store(Provider())
        store.reportRenewalFailed(providerID: "claude", command: "claude")
        store.reportRenewalFailed(providerID: "claude", command: "claude")
        XCTAssertEqual(store.needsRenewal, ["claude": "claude"])
    }

    // MARK: - Disappearance

    /// A reading that came back is proof the credential works, whatever was
    /// believed a moment ago. This is the only thing that clears the warning —
    /// no timer, and nothing retries on its own.
    func testItClearsOnceAReadingComesBack() async {
        let provider = Provider()
        let store = store(provider)
        provider.tokenExpired = true
        store.reportRenewalFailed(providerID: "claude", command: "claude")
        await store.refresh()
        XCTAssertTrue(warning(store))

        provider.tokenExpired = false
        await store.refresh()

        XCTAssertFalse(warning(store), "a fresh reading takes the warning away by itself")
        XCTAssertTrue(store.needsRenewal.isEmpty)
    }

    /// A failed fetch is not proof of anything, so it must not clear it either.
    func testAFailedFetchDoesNotClearIt() async {
        let provider = Provider()
        let store = store(provider)
        provider.tokenExpired = true
        store.reportRenewalFailed(providerID: "claude", command: "claude")
        await store.refresh()
        await store.refresh()
        XCTAssertTrue(warning(store))
    }

    // MARK: - Naming the right command (#473)

    /// The default Claude profile is renewed by plain `claude`.
    func testTheDefaultClaudeProfileIsToldToRunClaude() {
        let profile = ClaudeProfile.default(home: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(
            ProviderSummary.renewalWarning(name: "Claude", command: profile.renewalCommand,
                                           locale: Locale(identifier: "en")),
            "Claude usage needs its sign-in renewed — run `claude` once in a terminal.")
    }

    /// A second Claude login is renewed only by naming its directory: plain
    /// `claude` would renew the default one and leave this one expired.
    func testASecondClaudeProfileIsToldToNameItsDirectory() {
        let profile = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/someone/.claude-work"))
        XCTAssertEqual(
            ProviderSummary.renewalWarning(name: "Claude (work)", command: profile.renewalCommand,
                                           locale: Locale(identifier: "en")),
            "Claude (work) usage needs its sign-in renewed — run "
            + "`CLAUDE_CONFIG_DIR='/Users/someone/.claude-work' claude` once in a terminal.")
    }

    /// Codex is renewed by running `codex`, never `claude`.
    func testTheDefaultCodexProfileIsToldToRunCodex() {
        let profile = CodexProfile.default(home: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(
            ProviderSummary.renewalWarning(name: "Codex", command: profile.renewalCommand,
                                           locale: Locale(identifier: "en")),
            "Codex usage needs its sign-in renewed — run `codex` once in a terminal.")
    }

    func testASecondCodexProfileIsToldToNameItsHome() {
        let profile = CodexProfile(slug: "personal",
                                   configDirectory: URL(fileURLWithPath: "/Users/someone/.codex-personal"))
        XCTAssertEqual(
            ProviderSummary.renewalWarning(name: "Codex (personal)", command: profile.renewalCommand,
                                           locale: Locale(identifier: "en")),
            "Codex (personal) usage needs its sign-in renewed — run "
            + "`CODEX_HOME='/Users/someone/.codex-personal' codex` once in a terminal.")
    }

    /// The command goes into the translations too, not just the English.
    func testATranslationCarriesTheCommand() {
        XCTAssertEqual(
            ProviderSummary.renewalWarning(name: "Codex", command: "codex",
                                           locale: Locale(identifier: "zh-Hans")),
            "Codex 用量需要重新登录 — 在终端里运行一次 `codex`。")
    }

    /// The row that failed carries its own command, and no other row warns.
    func testEachRowNamesItsOwnCommand() {
        let store = store(Provider(), Provider(id: "claude-work", displayName: "Claude (work)"))
        store.reportRenewalFailed(providerID: "claude-work",
                                  command: "CLAUDE_CONFIG_DIR='/Users/someone/.claude-work' claude")
        XCTAssertNil(text(store, "claude"))
        XCTAssertEqual(text(store, "claude-work"),
                       "Claude (work) usage needs its sign-in renewed — run "
                       + "`CLAUDE_CONFIG_DIR='/Users/someone/.claude-work' claude` once in a terminal.")
    }

    // MARK: - A Codex failure reaches the warning (#473)

    /// A Codex renewal that ran without moving the expiry, or could not start
    /// at all, shows the same Settings warning as a Claude one — on the row of
    /// the profile that failed, naming that profile's command.
    func testACodexFailureReachesTheWarning() async {
        for throwing in [false, true] {
            // Nothing is read from disk: the expiry and the command are stood in for.
            let home = URL(fileURLWithPath: "/Users/someone")
            let primary = CodexProfile.default(home: home)
            let personal = CodexProfile(slug: "personal",
                                        configDirectory: home.appendingPathComponent(".codex-personal"))
            let store = store(Provider(id: "codex", displayName: "Codex"),
                              Provider(id: "codex-personal", displayName: "Codex (personal)"))
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let expiries = [primary.id: now.addingTimeInterval(10 * 24 * 3600),   // healthy
                            personal.id: now.addingTimeInterval(3600)]            // due, and stuck
            let refresher = CodexTokenRefresher(
                profiles: [primary, personal],
                cli: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                readExpiry: { expiries[$0.id] },
                launcher: { _, _, _, _ in if throwing { throw CancellationError() } })
            refresher.warn(through: { store })

            await refresher.renewDue(now: now)

            XCTAssertNil(text(store, "codex"), "the healthy profile has nothing to renew")
            XCTAssertEqual(text(store, "codex-personal"),
                           "Codex (personal) usage needs its sign-in renewed — run "
                           + "`\(personal.renewalCommand)` once in a terminal.",
                           "throwing: \(throwing)")
            XCTAssertTrue(personal.renewalCommand.hasPrefix("CODEX_HOME='"))
        }
    }

    // MARK: - A Codex warning stays until it is resolved

    /// Codex renewal is tried a day before expiry, so after a failure the old
    /// token keeps returning readings for hours. Clearing the warning on one
    /// hid the failure until the token died. These use real `auth.json` files
    /// in a temporary directory; nothing runs `codex`.
    private struct CodexSetup {
        let store: UsageStore
        let refresher: CodexTokenRefresher
        let healthy: CodexProfile
        let stuck: CodexProfile
        let launches: () -> Int
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Writes a stored sign-in whose access token expires at `exp`. `nonce`
    /// makes a different token with the same expiry.
    private func writeSignIn(_ profile: CodexProfile, expiring exp: Date, nonce: String = "") throws {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let claims = #"{"exp":\#(Int(exp.timeIntervalSince1970)),"n":"\#(nonce)"}"#
        let jwt = b64(#"{"alg":"none"}"#) + "." + b64(claims) + ".sig"
        let auth = #"{"tokens":{"access_token":"\#(jwt)","account_id":"a"}}"#
        try Data(auth.utf8).write(to: profile.authURL)
    }

    /// A healthy default profile and a second one due for renewal, wired to
    /// the store the way AppDelegate wires them. `renew` decides what the
    /// stand-in for `codex app-server` does with the due profile.
    private func codexSetup(renew: @escaping (CodexProfile) throws -> Void = { _ in }) throws -> CodexSetup {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenewalWarningTests.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let healthy = CodexProfile.default(home: home)
        let stuck = CodexProfile(slug: "personal", configDirectory: home.appendingPathComponent(".codex-personal"))
        for profile in [healthy, stuck] {
            try FileManager.default.createDirectory(at: profile.configDirectory,
                                                    withIntermediateDirectories: true)
        }
        try writeSignIn(healthy, expiring: now.addingTimeInterval(10 * 24 * 3600))
        try writeSignIn(stuck, expiring: now.addingTimeInterval(3600))

        let store = store(Provider(id: healthy.id, displayName: "Codex"),
                          Provider(id: stuck.id, displayName: "Codex (personal)"))
        var launches = 0
        let refresher = CodexTokenRefresher(
            profiles: [healthy, stuck],
            cli: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            launcher: { _, profile, _, _ in
                launches += 1
                try renew(profile)
            })
        refresher.warn(through: { store })
        return CodexSetup(store: store, refresher: refresher, healthy: healthy, stuck: stuck,
                          launches: { launches })
    }

    private func codexWarning(_ setup: CodexSetup, _ profile: CodexProfile) -> Bool {
        setup.store.providerSummaries.first { $0.id == profile.id }?.needsSignInRenewal ?? false
    }

    /// The regression: the old token still answers, a reading comes back, and
    /// the warning must stay — the refresher will not try that token again.
    func testAReadingDoesNotClearACodexWarning() async throws {
        let setup = try codexSetup()
        await setup.refresher.renewDue(now: now)
        XCTAssertTrue(codexWarning(setup, setup.stuck))

        await setup.store.refresh()
        await setup.store.refresh()
        await setup.refresher.renewDue(now: now.addingTimeInterval(1800))

        XCTAssertTrue(codexWarning(setup, setup.stuck), "a reading from the old token proves nothing")
        XCTAssertEqual(setup.store.needsRenewal, [setup.stuck.id: setup.stuck.renewalCommand])
        XCTAssertFalse(codexWarning(setup, setup.healthy), "the healthy profile never warns")
        XCTAssertEqual(setup.launches(), 1, "and the stuck token is still not retried")
    }

    /// A renewal that does move the expiry takes the warning away.
    func testASuccessfulRenewalClearsACodexWarning() async throws {
        let renewed = now.addingTimeInterval(10 * 24 * 3600)
        let setup = try codexSetup { try self.writeSignIn($0, expiring: renewed) }
        // A failure reported earlier, standing when this renewal runs.
        setup.refresher.onFailure?(setup.stuck.id, setup.stuck.renewalCommand)
        await setup.store.refresh()
        XCTAssertTrue(codexWarning(setup, setup.stuck))

        await setup.refresher.renewDue(now: now)

        XCTAssertEqual(setup.refresher.outcomes[setup.stuck.id], .refreshed(until: renewed))
        XCTAssertFalse(codexWarning(setup, setup.stuck), "the renewal took it away")
        XCTAssertTrue(setup.store.needsRenewal.isEmpty)
        XCTAssertNil(setup.refresher.outcomes[setup.healthy.id], "the healthy profile was left alone")
    }

    /// The user ran the command: `auth.json` now holds a different token. The
    /// next reading notices, without waiting for the refresher's next tick.
    func testATokenChangeInAuthJSONClearsACodexWarning() async throws {
        let setup = try codexSetup()
        await setup.refresher.renewDue(now: now)
        await setup.store.refresh()
        XCTAssertTrue(codexWarning(setup, setup.stuck))

        let renewed = now.addingTimeInterval(10 * 24 * 3600)
        try writeSignIn(setup.stuck, expiring: renewed)       // what running `codex` does
        await setup.store.refresh()

        XCTAssertFalse(codexWarning(setup, setup.stuck), "the replaced token took it away")
        XCTAssertTrue(setup.store.needsRenewal.isEmpty)
        XCTAssertEqual(setup.refresher.outcomes[setup.stuck.id], .replaced(until: renewed))
        XCTAssertFalse(codexWarning(setup, setup.healthy))
    }

    /// The refresher's own tick notices a replaced token too, with no reading.
    func testTheRefresherTickNoticesAReplacedToken() async throws {
        let setup = try codexSetup()
        await setup.refresher.renewDue(now: now)
        XCTAssertTrue(codexWarning(setup, setup.stuck))

        let renewed = now.addingTimeInterval(10 * 24 * 3600)
        try writeSignIn(setup.stuck, expiring: renewed)
        await setup.refresher.renewDue(now: now.addingTimeInterval(1800))

        XCTAssertFalse(codexWarning(setup, setup.stuck))
        XCTAssertEqual(setup.refresher.outcomes[setup.stuck.id], .replaced(until: renewed))
        XCTAssertEqual(setup.launches(), 1, "a token with days left is not launched for")
    }

    /// A different token with the very same expiry still counts as replaced,
    /// and the one-attempt memory does not carry over to it: the new token
    /// gets its own renewal, and if that fails too, the warning returns.
    func testANewTokenWithTheSameExpiryClearsItAndIsRenewedInItsTurn() async throws {
        let setup = try codexSetup()
        await setup.refresher.renewDue(now: now)
        XCTAssertTrue(codexWarning(setup, setup.stuck))

        try writeSignIn(setup.stuck, expiring: now.addingTimeInterval(3600), nonce: "signed in again")
        await setup.store.refresh()
        XCTAssertFalse(codexWarning(setup, setup.stuck), "a different token, same expiry")

        await setup.refresher.renewDue(now: now.addingTimeInterval(60))
        XCTAssertEqual(setup.launches(), 2, "the new token is not blocked by the old one's attempt")
        XCTAssertTrue(codexWarning(setup, setup.stuck), "and its own failure is reported")
        XCTAssertFalse(codexWarning(setup, setup.healthy))
    }
}
