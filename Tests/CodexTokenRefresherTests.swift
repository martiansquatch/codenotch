import XCTest
@testable import Codenotch

/// #473: every Codex profile's `auth.json` is renewed before it expires.
///
/// Simulated accounts only: two fake `auth.json` sign-ins in a temporary
/// directory, with the app server stood in for. Nothing here runs `codex`.
@MainActor
final class CodexTokenRefresherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let cli = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    private struct Boom: Error {}

    private func makeHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenRefresherTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func profile(_ slug: String?, in home: URL) throws -> CodexProfile {
        let profile = slug.map {
            CodexProfile(slug: $0, configDirectory: home.appendingPathComponent(".codex-\($0)"))
        } ?? .default(home: home)
        try FileManager.default.createDirectory(at: profile.configDirectory,
                                                withIntermediateDirectories: true)
        return profile
    }

    /// Writes a fake stored sign-in whose access token expires at `exp`.
    private func writeSignIn(_ profile: CodexProfile, expiring exp: Date) throws {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let jwt = b64(#"{"alg":"none"}"#) + "." + b64(#"{"exp":\#(Int(exp.timeIntervalSince1970))}"#) + ".sig"
        let auth = #"{"tokens":{"access_token":"\#(jwt)","account_id":"a"}}"#
        try Data(auth.utf8).write(to: profile.authURL)
    }

    private func expiry(_ profile: CodexProfile) -> Date? { CodexTokenRefresher.expiry(of: profile) }

    func testReadsTheExpiryFromTheAccessToken() throws {
        let home = try makeHome()
        let p = try profile(nil, in: home)
        try writeSignIn(p, expiring: Date(timeIntervalSince1970: 2_000_000_000))

        XCTAssertEqual(expiry(p), Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testNoFileMeansNoExpiryAndNoLaunch() async throws {
        let home = try makeHome()
        let p = try profile("personal", in: home)
        var launches = 0
        let refresher = CodexTokenRefresher(profiles: [p], cli: cli,
                                            launcher: { _, _, _, _ in launches += 1 })

        await refresher.renewDue(now: now)

        XCTAssertNil(expiry(p))
        XCTAssertEqual(launches, 0)
    }

    func testNeverLaunchesWithoutTheCommand() async throws {
        let home = try makeHome()
        let p = try profile("personal", in: home)
        try writeSignIn(p, expiring: now.addingTimeInterval(60))
        var launches = 0
        let refresher = CodexTokenRefresher(profiles: [p], cli: nil,
                                            launcher: { _, _, _, _ in launches += 1 })

        await refresher.renewDue(now: now)

        XCTAssertEqual(launches, 0)
    }

    /// Two sign-ins both inside a day of expiry: both are renewed, each with
    /// its own profile handed to the app server.
    func testBothProfilesAreRenewed() async throws {
        let home = try makeHome()
        let primary = try profile(nil, in: home)
        let personal = try profile("personal", in: home)
        try writeSignIn(primary, expiring: now.addingTimeInterval(3600))
        try writeSignIn(personal, expiring: now.addingTimeInterval(7200))
        let renewed = now.addingTimeInterval(10 * 24 * 3600)
        var launched: [String] = []

        let refresher = CodexTokenRefresher(profiles: [primary, personal], cli: cli) { _, profile, _, done in
            launched.append(profile.configDirectory.lastPathComponent)
            try self.writeSignIn(profile, expiring: renewed)   // what Codex itself does
            XCTAssertTrue(done(), "the wait should end as soon as the expiry moves")
        }

        await refresher.renewDue(now: now)

        XCTAssertEqual(launched, [".codex", ".codex-personal"])
        XCTAssertEqual(expiry(primary), renewed)
        XCTAssertEqual(expiry(personal), renewed)
        XCTAssertEqual(refresher.outcomes[primary.id], .refreshed(until: renewed))
        XCTAssertEqual(refresher.outcomes[personal.id], .refreshed(until: renewed))
    }

    /// The first profile failing — either by not moving or by not starting —
    /// does not stop the second from being renewed.
    func testAFailureOnOneDoesNotBlockTheOther() async throws {
        for throwing in [false, true] {
            let home = try makeHome()
            let primary = try profile(nil, in: home)
            let personal = try profile("personal", in: home)
            let stuck = now.addingTimeInterval(3600)
            try writeSignIn(primary, expiring: stuck)
            try writeSignIn(personal, expiring: now.addingTimeInterval(3600))
            let renewed = now.addingTimeInterval(10 * 24 * 3600)

            let refresher = CodexTokenRefresher(profiles: [primary, personal], cli: cli) { _, profile, _, _ in
                if profile == primary {
                    if throwing { throw Boom() }
                    return   // ran, but the expiry did not move
                }
                try self.writeSignIn(profile, expiring: renewed)
            }

            await refresher.renewDue(now: now)

            guard case .failed = refresher.outcomes[primary.id] else {
                return XCTFail("primary should have failed (throwing: \(throwing)), got \(String(describing: refresher.outcomes[primary.id]))")
            }
            XCTAssertEqual(expiry(primary), stuck)
            XCTAssertEqual(refresher.outcomes[personal.id], .refreshed(until: renewed),
                           "personal was held back (throwing: \(throwing))")
            XCTAssertEqual(expiry(personal), renewed)
        }
    }

    /// One attempt per token: a profile whose renewal did not move the expiry
    /// is not launched again on later ticks, while a healthy one is left alone.
    func testAFailureDoesNotLoopAndAHealthyTokenIsLeftAlone() async throws {
        let home = try makeHome()
        let primary = try profile(nil, in: home)
        let personal = try profile("personal", in: home)
        try writeSignIn(primary, expiring: now.addingTimeInterval(5 * 24 * 3600))   // healthy
        try writeSignIn(personal, expiring: now.addingTimeInterval(3600))           // due
        var launched: [String] = []

        let refresher = CodexTokenRefresher(profiles: [primary, personal], cli: cli) { _, profile, _, _ in
            launched.append(profile.id)
        }

        await refresher.renewDue(now: now)
        await refresher.renewDue(now: now.addingTimeInterval(1800))
        await refresher.renewDue(now: now.addingTimeInterval(3000))

        XCTAssertEqual(launched, [personal.id])
        XCTAssertNil(refresher.outcomes[primary.id])
    }

    func testTheAppServerRunsAgainstTheProfilesOwnHome() {
        let p = CodexProfile(slug: "personal",
                             configDirectory: URL(fileURLWithPath: "/Users/someone/.codex-personal"))
        let env = CodexTokenRefresher.environment(base: ["CODEX_HOME": "/Users/someone/.codex"], profile: p)
        XCTAssertEqual(env["CODEX_HOME"], "/Users/someone/.codex-personal")
    }

    /// The renewal asks only for the account: no turn, no model call.
    func testItOnlyAsksForTheAccount() {
        let methods = CodexTokenRefresher.requests.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["method"] as? String
        }
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read"])
        XCTAssertTrue(CodexTokenRefresher.requests[2].contains(#""refreshToken":true"#))
    }
}
