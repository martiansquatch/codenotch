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
            refresher.onFailure = store.reportRenewalFailed(providerID:command:)

            await refresher.renewDue(now: now)

            XCTAssertNil(text(store, "codex"), "the healthy profile has nothing to renew")
            XCTAssertEqual(text(store, "codex-personal"),
                           "Codex (personal) usage needs its sign-in renewed — run "
                           + "`\(personal.renewalCommand)` once in a terminal.",
                           "throwing: \(throwing)")
            XCTAssertTrue(personal.renewalCommand.hasPrefix("CODEX_HOME='"))
        }
    }
}
