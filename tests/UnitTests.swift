// Unit tests for the app's logic: parsing claude.ai's replies (against saved
// ones in tests/fixtures), cookie decryption, the stale/fallback rules, the
// forecast, history and version compare. Compiled with the app's sources by
// scripts/unit-tests.sh; no XCTest, so the Command Line Tools are enough.
// Never touches the network, the Keychain or real profiles.

import Foundation
import CommonCrypto

private var failures = 0
private var checks = 0
private var current = ""

private func expect(_ ok: Bool, _ what: @autoclosure () -> String = "", line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL \(current) (UnitTests.swift:\(line)) \(what())")
    }
}

private func equal<T: Equatable>(_ a: T, _ b: T, line: Int = #line) {
    expect(a == b, "\(a) != \(b)", line: line)
}

private func test(_ name: String, _ body: () throws -> Void) {
    current = name
    do { try body() } catch { failures += 1; print("FAIL \(name): threw \(error)") }
}

private func test(_ name: String, _ body: () async throws -> Void) async {
    current = name
    do { try await body() } catch { failures += 1; print("FAIL \(name): threw \(error)") }
}

private var fixtures = "tests/fixtures"
private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: fixtures + "/" + name))
}
private func fixtureJSON(_ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: try fixture(name))
}

private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

// AES-128-CBC the way Chromium stores cookies on macOS: "v10" + ciphertext.
private func encryptCookie(_ plain: Data, key: Data) -> Data {
    var out = Data(count: plain.count + kCCBlockSizeAES128)
    var n = 0
    let cap = out.count
    let iv = [UInt8](repeating: 0x20, count: 16)
    _ = out.withUnsafeMutableBytes { o in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                [UInt8](key), 16, iv, [UInt8](plain), plain.count, o.baseAddress, cap, &n)
    }
    return Data("v10".utf8) + out.prefix(n)
}

@main
enum UnitTests {
    static func main() async {
        if CommandLine.arguments.count > 1 { fixtures = CommandLine.arguments[1] }

        // MARK: versions

        test("versionLessThan") {
            expect(versionLessThan("0.9.0", "0.9.1"))
            expect(versionLessThan("0.9.9", "0.10.0"))
            expect(versionLessThan("1.2", "1.2.1"))
            expect(!versionLessThan("1.2.0", "1.2"))
            expect(!versionLessThan("0.10.0", "0.9.9"))
            expect(!versionLessThan("1.0.0", "1.0.0"))
        }

        // MARK: claude.ai replies

        test("parseUsageReply reads limits, resets and model limits") {
            let j = try fixtureJSON("usage-chat.json") as! [String: Any]
            let u = parseUsageReply(j)
            equal(u.fiveHour, 42)
            equal(u.sevenDay, 17)
            equal(u.error, nil)
            // Microseconds and a numeric offset, as claude.ai sends them.
            expect(u.fiveHourReset != nil, "five_hour resets_at didn't parse")
            equal(u.fiveHourReset.map { Int($0.timeIntervalSince1970) }, Int(iso("2026-11-25T15:00:00Z").timeIntervalSince1970))
            equal(u.sevenDayReset, iso("2026-11-28T09:00:00Z"))
            // Null limits are skipped, strings are read as numbers, unknown
            // families get a readable label, sorted by key.
            equal(u.models.map(\.key), ["seven_day_new_family", "seven_day_opus"])
            equal(u.models.map(\.label), ["New Family", "Opus"])
            equal(u.models.map(\.used), [3, 8.5])
            equal(u.models.first?.reset, nil)
        }

        test("parseUsageReply on an organization without chat limits") {
            let u = parseUsageReply(try fixtureJSON("usage-api.json") as! [String: Any])
            expect(u.hasNoData)
            expect(u.models.isEmpty)
        }

        await test("An unknown provider's usage isn't read: it needs a newer Lanes") {
            do { _ = try await Providers.named("future-app").fetchUsage(dataDir: "/x"); expect(false) }
            catch {
                let u = Usage(error: error.localizedDescription)
                equal(u.error, "needs a newer Lanes")
                expect(!u.needsSignIn)
            }
        }

        await test("usage() skips organizations without numbers") {
            let orgs = try fixtureJSON("organizations.json")
            var asked: [String] = []
            let r = try await usage(organizations: orgs) { id in
                asked.append(id)
                return try fixtureJSON(id.hasSuffix("1") ? "usage-api.json" : "usage-chat.json")
            }
            equal(asked.count, 2)
            equal(r.usage.fiveHour, 42)
            equal(r.raw.count, 2)
            equal(r.raw.last?["name"] as? String, "Personal")
        }

        await test("usage() survives one organization failing") {
            let orgs = try fixtureJSON("organizations.json")
            let r = try await usage(organizations: orgs) { id in
                if id.hasSuffix("1") { throw usageError("HTTP 500") }
                return try fixtureJSON("usage-chat.json")
            }
            equal(r.usage.sevenDay, 17)
        }

        await test("usage() flags a format change when no organization answers") {
            let orgs = try fixtureJSON("organizations.json")
            let r = try await usage(organizations: orgs) { _ in ["unexpected": true] as [String: Any] }
            expect(r.usage.hasNoData, "an empty reply should read as no data")
            let none = try await usage(organizations: orgs) { _ in throw usageError("HTTP 404", formatChanged: true) }
            equal(none.usage.error, "unexpected response")
            expect(none.usage.formatChanged)
        }

        await test("usage() with no organizations throws") {
            for orgs: Any in [[[String: Any]](), ["not": "a list"]] {
                do {
                    _ = try await usage(organizations: orgs) { _ in [:] as [String: Any] }
                    expect(false, "expected a throw for \(orgs)")
                } catch {
                    equal(error.localizedDescription, "no organization")
                }
            }
        }

        test("isFormatError") {
            expect(isFormatError(usageError("HTTP 404", formatChanged: true)))
            expect(!isFormatError(usageError("HTTP 500")))
            expect(isFormatError(NSError(domain: NSCocoaErrorDomain, code: 3840)))
            expect(!isFormatError(URLError(.timedOut)))
        }

        // MARK: cookies

        test("decryptCookie round-trips Chromium's v10 format") {
            let key = try ChromiumKey.derive(password: "test-password")
            equal(key.count, 16)
            equal(try ChromiumKey.derive(password: "test-password"), key)
            expect(try ChromiumKey.derive(password: "other") != key)
            let blob = encryptCookie(Data("sk-ant-abc".utf8), key: key)
            equal(decryptCookie(blob, key: key), "sk-ant-abc")
            // Newer Chromium: a 32-byte host hash before the value.
            let hashed = encryptCookie(Data(repeating: 0xFF, count: 32) + Data("value".utf8), key: key)
            equal(decryptCookie(hashed, key: key), "value")
            // Not v10, or the wrong key.
            equal(decryptCookie(Data("v11xxxxxxxxxxxxxxxx".utf8), key: key), nil)
            equal(decryptCookie(blob, key: try ChromiumKey.derive(password: "other")), nil)
        }

        test("Data(hexString:)") {
            equal(Data(hexString: "00ff10"), Data([0x00, 0xFF, 0x10]))
            equal(Data(hexString: "abc"), nil)
            equal(Data(hexString: "zz"), nil)
        }

        // MARK: Claude Desktop's record

        test("LocalUsage.latest picks the newest reading with numbers") {
            let r = LocalUsage.latest(json: try fixture("plan-usage-history.json"))
            equal(r?.t, Date(timeIntervalSince1970: 1795604411.441))
            equal(r?.fiveHour, 22)
            equal(r?.sevenDay, 39)
            equal(LocalUsage.latest(json: Data("not json".utf8)), nil)
            equal(LocalUsage.latest(json: Data(#"{"version":3,"samples":"nope"}"#.utf8)), nil)
            equal(LocalUsage.latest(json: Data(#"{"samples":[]}"#.utf8)), nil)
            equal(LocalUsage.latest(dataDir: "/nonexistent"), nil)
        }

        // MARK: stale numbers and the fallback

        let now = iso("2026-11-25T12:00:00Z")
        let ok = Usage(fiveHour: 40, sevenDay: 20, fiveHourReset: now.addingTimeInterval(3600),
                       sevenDayReset: now.addingTimeInterval(3 * 86400), error: nil)
        let failed = Usage(fiveHour: nil, sevenDay: nil, error: "HTTP 500")
        func merge(_ fresh: Usage, prev: Usage?, at: Date?, local: LocalUsage.Reading?) -> Usage {
            ProfileStore.merge(fresh: fresh, previous: prev, previousAt: at, local: local, now: now)
        }

        test("merge: a successful check passes through") {
            equal(merge(ok, prev: nil, at: nil, local: nil), ok)
        }

        test("merge: signing out clears the lane at once") {
            let out = Usage(fiveHour: nil, sevenDay: nil, error: "session expired")
            equal(merge(out, prev: ok, at: now, local: LocalUsage.Reading(t: now, fiveHour: 1, sevenDay: 1)), out)
        }

        test("merge: a failed check keeps the last numbers for an hour") {
            let at = now.addingTimeInterval(-600)
            let u = merge(failed, prev: ok, at: at, local: nil)
            equal(u.fiveHour, 40)
            equal(u.staleSince, at)
            equal(u.staleError, "HTTP 500")
            expect(!u.fromLocalRecord)
            // Already stale: the clock runs from the first failure.
            equal(merge(failed, prev: u, at: now, local: nil).staleSince, at)
            // Past the hour: blank.
            equal(merge(failed, prev: ok, at: now.addingTimeInterval(-3601), local: nil), failed)
        }

        test("merge: Claude Desktop's newer reading wins") {
            let local = LocalUsage.Reading(t: now.addingTimeInterval(-120), fiveHour: 55, sevenDay: 21)
            let u = merge(failed, prev: ok, at: now.addingTimeInterval(-600), local: local)
            equal(u.fiveHour, 55)
            equal(u.sevenDay, 21)
            equal(u.staleSince, local.t)
            expect(u.fromLocalRecord)
            // The previous reset times still ahead, and after the reading, are kept.
            equal(u.fiveHourReset, ok.fiveHourReset)
            equal(u.sevenDayReset, ok.sevenDayReset)
        }

        test("merge: Claude Desktop's older reading loses") {
            let local = LocalUsage.Reading(t: now.addingTimeInterval(-1200), fiveHour: 5, sevenDay: 5)
            let u = merge(failed, prev: ok, at: now.addingTimeInterval(-600), local: local)
            equal(u.fiveHour, 40)
            expect(!u.fromLocalRecord)
        }

        test("merge: no reading of Lanes' own yet (launched offline)") {
            let local = LocalUsage.Reading(t: now.addingTimeInterval(-900), fiveHour: 12, sevenDay: nil)
            let u = merge(failed, prev: nil, at: nil, local: local)
            equal(u.fiveHour, 12)
            equal(u.sevenDay, nil)
            equal(u.fiveHourReset, nil)
            expect(u.fromLocalRecord)
            expect(!u.hasNoData)
            // Too old to show.
            let old = LocalUsage.Reading(t: now.addingTimeInterval(-7200), fiveHour: 12, sevenDay: nil)
            equal(merge(failed, prev: nil, at: nil, local: old), failed)
        }

        test("merge: a reset that has passed isn't carried over") {
            var prev = ok
            prev.fiveHourReset = now.addingTimeInterval(-60)
            let local = LocalUsage.Reading(t: now.addingTimeInterval(-30), fiveHour: 3, sevenDay: 20)
            let u = merge(failed, prev: prev, at: now.addingTimeInterval(-600), local: local)
            equal(u.fiveHourReset, nil)
            equal(u.sevenDayReset, ok.sevenDayReset)
        }

        test("merge: a format change is still reported while stale") {
            let gone = Usage(fiveHour: nil, sevenDay: nil, error: "HTTP 404", formatChanged: true)
            let u = merge(gone, prev: ok, at: now, local: nil)
            expect(u.formatChanged)
            equal(u.staleError, "HTTP 404")
        }

        // MARK: timeouts

        await test("withTimeout returns a fast result") {
            let v = try await withTimeout(1) { 7 }
            equal(v, 7)
        }

        await test("withTimeout gives up on a slow one") {
            let start = Date()
            do {
                _ = try await withTimeout(0.2) { () async throws -> Int in
                    try await offCooperativePool { Thread.sleep(forTimeInterval: 2); return 1 }
                }
                expect(false, "expected a timeout")
            } catch {
                equal(error.localizedDescription, "timed out")
                expect(Date().timeIntervalSince(start) < 1.5, "took \(Date().timeIntervalSince(start))s")
            }
        }

        await test("withTimeout passes errors through") {
            do {
                _ = try await withTimeout(1) { () async throws -> Int in throw usageError("not signed in") }
                expect(false, "expected a throw")
            } catch {
                equal(error.localizedDescription, "not signed in")
            }
        }

        // MARK: forecast and history

        test("Forecast.pace projects the recent rate to the reset") {
            let reset = now.addingTimeInterval(2 * 3600)
            // 10% → 30% over the last hour: 20%/h, two hours left.
            let p = Forecast.pace(value: 30, reset: reset, window: ClaudeLimit.fiveHourWindow,
                                  samples: [(now.addingTimeInterval(-3600), 10)], lookback: 3600, minSpan: 900, now: now)
            equal(p.map { ($0.atReset * 10).rounded() / 10 }, 70)
            equal(p?.runsOutAt, nil)
            // 40%/h from 60%: out in an hour, before the reset.
            let fast = Forecast.pace(value: 60, reset: reset, window: ClaudeLimit.fiveHourWindow,
                                     samples: [(now.addingTimeInterval(-3600), 20)], lookback: 3600, minSpan: 900, now: now)
            equal(fast?.atReset, 100)
            equal(fast?.runsOutAt.map { Int($0.timeIntervalSince(now)) }, 3600)
        }

        test("Forecast.pace needs enough history, in this window") {
            let reset = now.addingTimeInterval(2 * 3600)
            equal(Forecast.pace(value: 30, reset: reset, window: ClaudeLimit.fiveHourWindow,
                                samples: [(now.addingTimeInterval(-300), 10)], lookback: 3600, minSpan: 900, now: now), nil)
            // A reading from before the window started (reset - 5h) doesn't count.
            equal(Forecast.pace(value: 30, reset: now.addingTimeInterval(4.9 * 3600), window: ClaudeLimit.fiveHourWindow,
                                samples: [(now.addingTimeInterval(-1800), 10)], lookback: 3600, minSpan: 900, now: now), nil)
            // Usage going down (a reset in between) counts as none.
            equal(Forecast.pace(value: 30, reset: reset, window: ClaudeLimit.fiveHourWindow,
                                samples: [(now.addingTimeInterval(-3600), 80)], lookback: 3600, minSpan: 900, now: now)?.atReset, 30)
            equal(Forecast.pace(value: 100, reset: reset, window: ClaudeLimit.fiveHourWindow,
                                samples: [(now.addingTimeInterval(-3600), 10)], lookback: 3600, minSpan: 900, now: now), nil)
        }

        // MARK: providers

        test("A profile's .lanes-provider names its provider, missing means claude") {
            let dir = NSTemporaryDirectory() + "lanes-provider-test-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let file = dir + "/.lanes-provider"
            equal(Providers.id(ofProfileAt: dir), "claude")
            for (text, id) in [("claude\n", "claude"), (" chatgpt \r\nignored", "chatgpt"), ("", "claude"),
                               ("\nchatgpt", "claude"), ("  \n", "claude")] {
                try text.write(toFile: file, atomically: true, encoding: .utf8)
                equal(Providers.id(ofProfileAt: dir), id)
            }
            // A provider this Lanes doesn't know is never taken for Claude
            // (bin/lanes refuses to launch it): shown as it is, unread.
            equal(Providers.named("chatgpt").id, "chatgpt")
            let unknown = Providers.named("future-app")
            equal(unknown.id, "future-app")
            expect(!unknown.isKnown && Providers.claude.isKnown && Providers.chatgpt.isKnown)
            expect(!unknown.isMainProcess("/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/x"))
            expect(!unknown.isMainProcess("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT --user-data-dir=/x"))
            equal(unknown.linkScheme, nil)
            equal(unknown.renewsSignIn, false)
            equal(Profile(name: "Odd", dataDir: dir, colorName: "blue", providerID: "future-app").provider.id, "future-app")
            let p = Profile(name: "Work", dataDir: dir, colorName: "blue")
            equal(p.providerID, "claude")
            equal(p.provider.id, "claude")
        }

        test("ClaudeProvider: the values bin/lanes keeps too") {
            let c = Providers.claude
            equal(c.id, "claude")
            equal(c.executable, "Claude")
            equal(c.bundleID, "com.anthropic.claudefordesktop")
            equal(c.configEnv, "CLAUDE_CONFIG_DIR")
            equal(c.configSubdir, "claude-config")
            equal(c.linkScheme, "claude")
            equal(c.probeURL, URL(string: "claude://"))
            equal(c.appCandidates, ["/Applications/Claude.app", NSHomeDirectory() + "/Applications/Claude.app"])
            equal(c.clonePath(in: "/c", profile: "Work"), "/c/Claude Work.app")
            expect(c.updater == .squirrel && c.iconStyle == .hueShift)
        }

        test("Process matching: main processes only, the install apart from clones") {
            let c = Providers.claude
            let main = "/Applications/Claude.app/Contents/MacOS/Claude"
            let clone = "/x/apps/Claude Work.app/Contents/MacOS/Claude --user-data-dir=/x/profiles/Work"
            let helper = "/x/apps/Claude Work.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --user-data-dir=/x/profiles/Work"
            expect(c.isMainProcess(main) && c.isInstalledApp(main))
            expect(c.isMainProcess(clone) && !c.isInstalledApp(clone))
            expect(!c.isMainProcess(helper))
            expect(!c.isMainProcess("/Applications/Lanes.app/Contents/MacOS/Lanes"))
        }

        test("ChatGPTProvider: the values bin/lanes keeps too") {
            let g = Providers.chatgpt
            equal(g.id, "chatgpt")
            equal(g.name, "ChatGPT")
            equal(g.executable, "ChatGPT")
            equal(g.bundleID, "com.openai.codex")
            equal(g.configEnv, "CODEX_HOME")
            equal(g.configSubdir, "codex-home")
            equal(g.linkScheme, nil)
            equal(g.probeURL, nil)
            equal(g.keychainItem, nil)
            equal(g.appCandidates, ["/Applications/ChatGPT.app", NSHomeDirectory() + "/Applications/ChatGPT.app"])
            equal(g.clonePath(in: "/c", profile: "Work"), "/c/ChatGPT Work.app")
            expect(g.updater == .sparkle && g.iconStyle == .tintedPlate)
            // An expired ChatGPT sign-in renews once the app runs; Claude's doesn't.
            expect(g.renewsSignIn && !Providers.claude.renewsSignIn)
            // Its processes and Claude's are told apart; helpers and the
            // bundled codex CLI aren't main processes.
            let clone = "/x/apps/ChatGPT Work.app/Contents/MacOS/ChatGPT --user-data-dir=/x/profiles/Work"
            let cli = "/x/apps/ChatGPT Work.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server"
            let helper = "/x/apps/ChatGPT Work.app/Contents/Frameworks/ChatGPT Helper (GPU).app/Contents/MacOS/ChatGPT Helper (GPU) --user-data-dir=/x/profiles/Work"
            expect(g.isMainProcess(clone) && !g.isInstalledApp(clone))
            expect(g.isInstalledApp("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
            expect(!g.isMainProcess(cli) && !g.isMainProcess(helper))
            expect(!Providers.claude.isMainProcess(clone) && !g.isMainProcess("/Applications/Claude.app/Contents/MacOS/Claude"))
        }

        test("ChatGPT usage: Plus has a 5-hour and a weekly window") {
            let u = try ChatGPTUsage.parse(try fixture("wham-usage-plus.json"))
            equal(u.limits.map(\.key), ["primary", "secondary"])
            equal(u.limits.map(\.window), [18000, 604800])
            equal(u.limits.map(\.label), ["5 hours", "Week"])
            equal(u.limits.map(\.tag), ["5h", "7d"])
            equal(u.primary?.used, 23)
            equal(u.secondary?.used, 41)
            equal(u.primary?.reset, Date(timeIntervalSince1970: 1790009000))
            equal(u.error, nil)
        }

        test("ChatGPT usage: Free has one 30-day window, reset from reset_after_seconds") {
            let now = Date(timeIntervalSince1970: 1790000000)
            let u = try ChatGPTUsage.parse(try fixture("wham-usage-free.json"), now: now)
            equal(u.limits.count, 1)
            equal(u.primary?.window, 30 * 86400)
            equal(u.primary?.label, "30 days")
            equal(u.primary?.noun, "30-day limit")
            equal(u.primary?.used, 40)
            equal(u.primary?.reset, now.addingTimeInterval(864000))
            equal(u.secondary, nil)
        }

        test("ChatGPT usage: another reply shape is a format change") {
            for body in ["{}", "{\"rate_limit\": {}}", "[]", "not json"] {
                do { _ = try ChatGPTUsage.parse(Data(body.utf8)); expect(false, body) }
                catch { expect(isFormatError(error), body) }
            }
        }

        test("ChatGPT sign-in: auth.json's token and account, never an expired one") {
            func jwt(exp: Double) -> String {
                let claims = try! JSONSerialization.data(withJSONObject: ["exp": exp])
                let b64 = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                return "eyJhbGciOiJub25lIn0.\(b64).sig"
            }
            let now = Date(timeIntervalSince1970: 1790000000)
            func auth(_ token: String) -> Data {
                Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"\(token)\",\"account_id\":\"acc-1\"}}".utf8)
            }
            let ok = try ChatGPTAuth.parse(auth(jwt(exp: 1790003600)), now: now)
            equal(ok.accountID, "acc-1")
            equal(ChatGPTAuth.jwtExpiry(ok.accessToken), Date(timeIntervalSince1970: 1790003600))
            do { _ = try ChatGPTAuth.parse(auth(jwt(exp: 1789999999)), now: now); expect(false) }
            catch { equal(error.localizedDescription, "session expired") }
            for body in ["{\"OPENAI_API_KEY\":\"sk-x\",\"tokens\":null}", "{}", "nope"] {
                do { _ = try ChatGPTAuth.parse(Data(body.utf8), now: now); expect(false, body) }
                catch { equal(error.localizedDescription, "not signed in") }
            }
            // A missing file is "not signed in", which Usage treats as such.
            do { _ = try ChatGPTAuth.read(codexHome: "/nonexistent-lanes-test"); expect(false) }
            catch { expect(Usage(error: error.localizedDescription).needsSignIn) }
        }

        test("ChatGPT's own record: the newest rate_limits, with reset times") {
            let home = NSTemporaryDirectory() + "lanes-codex-test-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: home) }
            let day = home + "/sessions/2026/11/27", older = home + "/sessions/2026/11/26"
            try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: older, withIntermediateDirectories: true)
            try fixture("codex-session.jsonl").write(to: URL(fileURLWithPath: day + "/rollout-b.jsonl"))
            try Data("{\"timestamp\":\"2026-11-26T00:00:00Z\",\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":99,\"window_minutes\":300}}}}\n".utf8)
                .write(to: URL(fileURLWithPath: older + "/rollout-a.jsonl"))
            let r = ChatGPTUsage.latestLocal(codexHome: home)
            equal(r?.t, iso("2026-11-27T06:19:50Z").addingTimeInterval(0.381))
            equal(r?.limits.map(\.used), [11, 10])
            equal(r?.limits.map(\.window), [18000, 604800])
            equal(r?.limits.first?.reset, Date(timeIntervalSince1970: 1790009000))
            equal(ChatGPTUsage.latestLocal(codexHome: "/nonexistent-lanes-test"), nil)
            // A resumed session appends to its older-dated file: its newer
            // reading wins over the newer-dated file's.
            let resumed = "{\"timestamp\":\"2026-11-27T07:00:00Z\",\"payload\":{\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":42,\"window_minutes\":300}}}}\n"
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: older + "/rollout-a.jsonl"))
            h.seekToEndOfFile(); h.write(Data(resumed.utf8)); try h.close()
            equal(ChatGPTUsage.latestLocal(codexHome: home)?.limits.map(\.used), [42])
            // Another limit (not the account's own) isn't read.
            let other = "{\"timestamp\":\"2026-11-27T00:00:00Z\",\"payload\":{\"rate_limits\":{\"limit_id\":\"x\",\"primary\":{\"used_percent\":1,\"window_minutes\":300}}}}"
            equal(ChatGPTUsage.localReading(Data(other.utf8)), nil)
        }

        test("Window labels for windows a provider doesn't name") {
            equal(UsageLimit.label(forWindow: 5 * 3600), "5 hours")
            equal(UsageLimit.label(forWindow: 7 * 86400), "Week")
            equal(UsageLimit.label(forWindow: 30 * 86400), "30 days")
            equal(UsageLimit.label(forWindow: 86400), "Day")
            equal(UsageLimit.label(forWindow: 3600), "Hour")
        }

        // MARK: limits as data

        test("Claude's usage is the 5-hour + weekly pair, in that order") {
            let t0 = Date(timeIntervalSince1970: 1_790_000_000)
            var u = Usage(fiveHour: 42, sevenDay: 17, fiveHourReset: t0 + 3600, sevenDayReset: t0 + 86400)
            equal(u.limits.map(\.key), ["five_hour", "seven_day"])
            equal(u.limits.map(\.label), ["5 hours", "Week"])
            equal(u.limits.map(\.window), [5 * 3600, 7 * 86400])
            equal(u.limits.map(\.tag), ["5h", "7d"])
            equal(u.limits.map(\.compactLabel), ["5h", "Week"])
            equal(u.limits.map(\.noun), ["5-hour limit", "weekly limit"])
            equal(u.primary?.used, 42)
            equal(u.secondary?.used, 17)
            u.sevenDayReset = nil
            equal(u.limit("seven_day")?.reset, nil)
            equal(u.fiveHourReset, t0 + 3600)
            // Both always there, even unknown: that's what hasNoData and the
            // snapshot's columns rely on.
            let none = Usage(fiveHour: nil, sevenDay: nil)
            equal(none.limits.count, 2)
            expect(none.hasNoData)
            // A Claude limit set on usage that lacks it lands in window order.
            var partial = Usage(limits: [ClaudeLimit.sevenDay(5, reset: nil)])
            partial.fiveHour = 9
            equal(partial.limits.map(\.key), ["five_hour", "seven_day"])
        }

        test("A single 30-day window is a full set of limits") {
            let t0 = Date(timeIntervalSince1970: 1_790_000_000)
            let month: TimeInterval = 30 * 86400
            let l = UsageLimit(key: "primary", label: "30 days", used: 40, reset: t0 + 10 * 86400, window: month)
            let u = Usage(limits: [l])
            equal(u.primary?.key, "primary")
            equal(u.secondary, nil)
            expect(!u.hasNoData)
            equal(l.tag, "30d")
            equal(l.compactLabel, "30d")
            equal(l.noun, "30-day limit")
            equal(UsageLimit.window(ofTag: l.tag), month)
            // 20 of its 30 days have passed.
            equal(elapsedFraction(reset: l.reset, window: month, now: t0).map { ($0 * 1000).rounded() }, 667)
            // Forecast: 10% → 40% over the last 3 days, 10 days left.
            let p = Forecast.pace(l, samples: [(t0 - 3 * 86400, 10)], now: t0)
            equal(p?.atReset, 100)
            equal(p?.runsOutAt.map { Int($0.timeIntervalSince(t0)) }, 6 * 86400)
            // History holds it as the first limit.
            equal(UsageSample(t: t0, h: 40, w: nil).value(at: 0), 40)

            // It ranks and publishes like Claude's first limit; no second
            // column, and the file says how long its window runs.
            let s = ProfileStore(live: false)
            s.profiles = [Profile(name: "Free", dataDir: "/tmp/Free", colorName: "blue", providerID: "chatgpt"),
                          Profile(name: "Plus", dataDir: "/tmp/Plus", colorName: "blue", providerID: "chatgpt"),
                          Profile(name: "Claude", dataDir: "/tmp/Claude", colorName: "orange")]
            s.usage = ["Free": u, "Plus": Usage(limits: [ClaudeLimit.fiveHour(60, reset: nil)]),
                       "Claude": Usage(fiveHour: 1, sevenDay: 1)]
            equal(s.bestProfile(provider: "chatgpt")?.name, "Free")
            let e = s.snapshotEntries()[0]
            equal(e.fiveHour, 40)
            equal(e.sevenDay, nil)
            equal(e.fiveHourReset, l.reset)
            equal(e.provider, "chatgpt")
            equal(e.fiveHourWindow, month)
            equal(e.sevenDayWindow, nil)
            equal(e.meters.map(\.label), ["30 days"])
            equal(ProfileStore.usageTSV([e], updated: t0),
                  "# updated 1790000000\nFree\tblue\t0\t40\t1790864000\t\t\t\t\t\t\t\tchatgpt\t2592000\t\n")
            let json = String(decoding: try UsageSnapshot.encoder.encode(e), as: UTF8.self)
            expect(json.contains("\"provider\" : \"chatgpt\"") && json.contains("\"fiveHourWindow\" : 2592000"), json)
            expect(!json.contains("sevenDayWindow"), json)
        }

        test("usage.json: a Claude entry has no provider or window fields; usage.tsv adds them at the end") {
            let t0 = Date(timeIntervalSince1970: 1_790_000_000)
            let s = ProfileStore(live: false)
            s.profiles = [Profile(name: "Work", dataDir: "/tmp/Work", colorName: "blue")]
            s.usage = ["Work": Usage(fiveHour: 20, sevenDay: 30)]
            let e = s.snapshotEntries()[0]
            equal(e.provider, nil)
            equal(e.fiveHourWindow, nil)
            let json = String(decoding: try UsageSnapshot.encoder.encode(e), as: UTF8.self)
            expect(!json.contains("provider") && !json.contains("Window"), json)
            equal(e.meters.map(\.label), ["5 hours", "Week"])
            equal(ProfileStore.usageTSV([e], updated: t0),
                  "# updated 1790000000\nWork\tblue\t0\t20\t\t30\t\t\t\t\t\t\tclaude\t18000\t604800\n")
            // An older app's entry (no provider) reads as Claude's.
            let old = try JSONDecoder().decode(UsageSnapshot.Entry.self,
                                                from: Data("{\"name\":\"A\",\"color\":\"red\",\"running\":false,\"fiveHour\":5}".utf8))
            equal(old.meters.map(\.window), [ClaudeLimit.fiveHourWindow, ClaudeLimit.sevenDayWindow])
        }

        test("History: windows only when not Claude's; forecasts skip another window's readings") {
            let t0 = Date(timeIntervalSince1970: 1_790_000_000)
            let claude = UsageSample(t: t0, h: 1, w: 2, hWindow: 18000, wWindow: 604800)
            equal(claude.hw, nil)
            equal(claude.ww, nil)
            let e = JSONEncoder()
            e.dateEncodingStrategy = .secondsSince1970
            // Sorted keys: JSONEncoder's key order otherwise varies run to run.
            e.outputFormatting = .sortedKeys
            equal(try e.encode(claude), try e.encode(UsageSample(t: t0, h: 1, w: 2)))
            expect(!String(decoding: try e.encode(claude), as: UTF8.self).contains("hw"))
            let free = UsageSample(t: t0, h: 40, w: nil, hWindow: 30 * 86400, wWindow: nil)
            equal(free.window(at: 0), 30 * 86400)
            equal(free.window(at: 1), ClaudeLimit.sevenDayWindow)
            expect(String(decoding: try e.encode(free), as: UTF8.self).contains("\"hw\":2592000"))

            // A profile that went from Free (30 days) to Plus (5 hours): the
            // 30-day readings don't feed the 5-hour forecast.
            let now = Date()
            var plus = Usage(limits: [ClaudeLimit.fiveHour(50, reset: now + 3600)])
            ProfileStore.forecast(&plus, history: [UsageSample(t: now - 1800, h: 0, w: nil, hWindow: 30 * 86400, wWindow: nil)], now: now)
            equal(plus.primary?.pace, nil)
            ProfileStore.forecast(&plus, history: [UsageSample(t: now - 1800, h: 0, w: nil)], now: now)
            expect(plus.primary?.pace != nil)
        }

        test("Most room: within one provider; Claude's first when none is given") {
            let s = ProfileStore(live: false)
            s.profiles = [Profile(name: "C1", dataDir: "/tmp/C1", colorName: "blue"),
                          Profile(name: "C2", dataDir: "/tmp/C2", colorName: "blue"),
                          Profile(name: "G1", dataDir: "/tmp/G1", colorName: "blue", providerID: "chatgpt"),
                          Profile(name: "G2", dataDir: "/tmp/G2", colorName: "blue", providerID: "chatgpt")]
            s.usage = ["C1": Usage(fiveHour: 90, sevenDay: 10), "C2": Usage(fiveHour: 70, sevenDay: 10),
                       "G1": Usage(fiveHour: 5, sevenDay: 10), "G2": Usage(fiveHour: 30, sevenDay: 10)]
            equal(s.bestProfile()?.name, "C2")
            equal(s.bestProfile(provider: "chatgpt")?.name, "G1")
            equal(s.roomiestProfile(provider: "chatgpt")?.name, "G1")
            // A Claude lane near its limit is pointed at another Claude lane,
            // never at a roomier ChatGPT one.
            equal(s.alternative(to: "G2")?.name, "G1")
            equal(s.alternative(to: "C1"), nil)
            // Only ChatGPT lanes with numbers: that's the best there is.
            s.usage = ["G1": Usage(fiveHour: 5, sevenDay: 10)]
            equal(s.bestProfile()?.name, "G1")
        }

        test("Reset alerts: one the usage no longer has is cancelled") {
            let pending = ["reset-5h-Work", "reset-7d-Work", "reset-30d-Work", "reset-5h-Work-2",
                           "reset-5h-Personal", "whats-new", "x-reset-5h-Work"]
            // Signed out or an error: no limits, so every reset alert goes.
            equal(ProfileStore.staleResetAlerts(pending, profile: "Work", keep: []),
                  ["reset-5h-Work", "reset-7d-Work", "reset-30d-Work"])
            // A plan change from 5h/7d to 30d keeps the new one only.
            equal(ProfileStore.staleResetAlerts(pending, profile: "Work", keep: ["reset-30d-Work"]),
                  ["reset-5h-Work", "reset-7d-Work"])
            equal(ProfileStore.staleResetAlerts(pending, profile: "Work-2", keep: []), ["reset-5h-Work-2"])
            equal(ProfileStore.resetAlertID(tag: "30d", profile: "Gpt Free"), "reset-30d-Gpt Free")
        }

        test("Links: a claude:// link only goes to Claude profiles") {
            let s = ProfileStore(live: false)
            s.profiles = [Profile(name: "C1", dataDir: "/tmp/C1", colorName: "blue"),
                          Profile(name: "G1", dataDir: "/tmp/G1", colorName: "blue", providerID: "chatgpt"),
                          Profile(name: "C2", dataDir: "/tmp/C2", colorName: "blue")]
            equal(s.linkTargets(for: URL(string: "claude://login/x?token=t")!).map(\.name), ["C1", "C2"])
            equal(s.linkTargets(for: URL(string: "CLAUDE://x")!).map(\.name), ["C1", "C2"])
            equal(s.linkTargets(for: URL(string: "codex://x")!).map(\.name), [])
        }

        test("Window timings come out exactly as Claude's old constants") {
            let five = WindowTiming(window: ClaudeLimit.fiveHourWindow)
            let week = WindowTiming(window: ClaudeLimit.sevenDayWindow)
            // Forecast lookback and minimum history: 1 h / 15 min, 1 day / 3 h.
            equal([five.lookback, five.minSpan], [3600, 15 * 60])
            equal([week.lookback, week.minSpan], [86400, 3 * 3600])
            // Pace alerts: within 45 min with 15 to spare, within a day with 6 h to spare.
            equal([five.paceSoon, five.paceSpare], [45 * 60, 15 * 60])
            equal([week.paceSoon, week.paceSpare], [86400, 6 * 3600])
            // Other windows scale between and beyond, in order.
            let day = WindowTiming(window: 86400), month = WindowTiming(window: 30 * 86400)
            for (lo, mid, hi) in [(five.lookback, day.lookback, week.lookback), (five.minSpan, day.minSpan, week.minSpan),
                                  (five.paceSoon, day.paceSoon, week.paceSoon), (five.paceSpare, day.paceSpare, week.paceSpare)] {
                expect(lo < mid && mid < hi, "\(lo) < \(mid) < \(hi)")
            }
            expect(month.lookback > week.lookback && month.minSpan > week.minSpan)
            expect(month.minSpan < month.lookback && month.paceSpare < month.paceSoon)
        }

        test("Forecast and pace alerts per limit match the old fixed rules") {
            let t0 = Date(timeIntervalSince1970: 1_790_000_000)
            // The per-limit forecast is the old call with the old constants.
            let cases: [(UsageLimit, TimeInterval, TimeInterval)] = [
                (ClaudeLimit.fiveHour(30, reset: t0 + 7200), 3600, 900),
                (ClaudeLimit.sevenDay(30, reset: t0 + 3 * 86400), 86400, 10800)]
            for (l, lookback, minSpan) in cases {
                for ago: TimeInterval in [600, 900, 1800, 3600, 3 * 3600, 6 * 3600, 86400, 2 * 86400] {
                    let samples: [(Date, Double)] = [(t0 - ago, 10)]
                    equal(Forecast.pace(l, samples: samples, now: t0),
                          Forecast.pace(value: l.used, reset: l.reset, window: l.window, samples: samples,
                                        lookback: lookback, minSpan: minSpan, now: t0))
                }
            }
            // 5 hours: runs out within 45 min, at least 15 min before the reset.
            let five = ClaudeLimit.fiveHour(50, reset: nil)
            func due(_ l: UsageLimit, out: TimeInterval, reset: TimeInterval) -> Bool {
                ProfileStore.paceAlertDue(l, runsOut: t0 + out, reset: t0 + reset, now: t0)
            }
            expect(due(five, out: 45 * 60, reset: 60 * 60))
            expect(!due(five, out: 45 * 60 + 1, reset: 2 * 3600))
            expect(!due(five, out: 30 * 60, reset: 30 * 60 + 14 * 60))
            // A week: within a day, at least 6 h before the reset.
            let week = ClaudeLimit.sevenDay(50, reset: nil)
            expect(due(week, out: 86400, reset: 86400 + 6 * 3600))
            expect(!due(week, out: 86400 + 1, reset: 3 * 86400))
            expect(!due(week, out: 3600, reset: 3600 + 6 * 3600 - 1))
        }

        test("Limit tags keep naming the alert state as before") {
            equal(UsageLimit.window(ofTag: "5h"), 5 * 3600)
            equal(UsageLimit.window(ofTag: "7d"), 7 * 86400)
            equal(UsageLimit.window(ofTag: "90m"), 90 * 60)
            equal(UsageLimit.window(ofTag: ""), nil)
            equal(UsageLimit.window(ofTag: "xh"), nil)
            equal(UsageLimit(key: "k", label: "", used: nil, reset: nil, window: 90 * 60).noun, "90-minute limit")
            // Muting from a notification uses that limit's window.
            let s = ProfileStore(live: false)
            s.alertMutedUntil = [:]
            let month: TimeInterval = 30 * 86400
            s.usage = ["Free": Usage(limits: [UsageLimit(key: "p", label: "30 days", used: 90, reset: nil, window: month)])]
            let before = Date()
            s.handleNotification(action: AlertAction.mute, info: ["profile": "Free", "limit": "30d"])
            expect((s.alertMutedUntil["Free/30d"] ?? 0) >= before.addingTimeInterval(month).timeIntervalSince1970)
            s.alertMutedUntil = [:]
        }

        test("merge: an app's own record keeps its own reset times") {
            let t0 = Date(timeIntervalSince1970: 1_790_000_000)
            let failed = Usage(error: "HTTP 500")
            let l = UsageLimit(key: "p", label: "30 days", used: 33, reset: t0 + 86400, window: 30 * 86400)
            let u = ProfileStore.merge(fresh: failed, previous: nil, previousAt: nil,
                                       local: LocalReading(t: t0 - 60, limits: [l]), now: t0)
            equal(u.primary?.used, 33)
            equal(u.primary?.reset, t0 + 86400)
            expect(u.fromLocalRecord)
        }

        test("merge: a record's limit whose own reset has passed starts over at 0") {
            let t0 = Date(timeIntervalSince1970: 1_790_000_000)
            let five = UsageLimit(key: "primary", label: "5 hours", used: 80, reset: t0 - 60, window: 18000)
            let week = UsageLimit(key: "secondary", label: "Week", used: 40, reset: t0 + 86400, window: 604800)
            let u = ProfileStore.merge(fresh: Usage(error: "HTTP 500"), previous: nil, previousAt: nil,
                                       local: LocalReading(t: t0 - 600, limits: [five, week]), now: t0)
            equal(u.limit("primary")?.used, 0)
            equal(u.limit("primary")?.reset, nil)
            equal(u.limit("secondary")?.used, 40)
            equal(u.limit("secondary")?.reset, t0 + 86400)
            // Claude's record has no reset times of its own: its numbers stay.
            let claude = ProfileStore.merge(fresh: Usage(error: "HTTP 500"), previous: nil, previousAt: nil,
                                            local: LocalReading(t: t0 - 600, limits: [ClaudeLimit.fiveHour(80, reset: nil)]), now: t0)
            equal(claude.primary?.used, 80)
        }

        test("UsageHistory keeps one reading per ~10 minutes, for 30 days") {
            var list: [UsageSample] = []
            let t0 = Date()
            UsageHistory.append(UsageSample(t: t0, h: 1, w: 1), to: &list)
            UsageHistory.append(UsageSample(t: t0.addingTimeInterval(300), h: 2, w: 1), to: &list)
            UsageHistory.append(UsageSample(t: t0.addingTimeInterval(600), h: 3, w: 1), to: &list)
            equal(list.map(\.h), [1, 3])
            var h: [String: [UsageSample]] = [
                "Work": [UsageSample(t: t0.addingTimeInterval(-31 * 86400), h: 1, w: 1)] + list,
                "Gone": list,
            ]
            UsageHistory.prune(&h, profiles: ["Work"])
            equal(h["Work"]?.count, 2)
            equal(h["Gone"] == nil, true)
            let csv = UsageHistory.csv([UsageSample(t: Date(timeIntervalSince1970: 0), h: 12.5, w: nil)])
            equal(csv, "time,five_hour,weekly\n1970-01-01T00:00:00Z,12.5,\n")
            // A ChatGPT Free profile's 30-day limit isn't called five_hour.
            let free = UsageHistory.csv([UsageSample(t: Date(timeIntervalSince1970: 0), h: 12.5, w: 3),
                                         UsageSample(t: Date(timeIntervalSince1970: 600), h: 40, w: nil, hWindow: 30 * 86400)])
            equal(free, "time,limit1,window1,limit2,window2\n1970-01-01T00:00:00Z,12.5,5h,3,7d\n1970-01-01T00:10:00Z,40,30d,,\n")
        }

        // MARK: best profile

        test("bestProfile: most 5-hour room, weekly breaks ties, a full week loses") {
            let s = ProfileStore(live: false)
            s.profiles = ["A", "B", "C", "D"].map { Profile(name: $0, dataDir: "/tmp/\($0)", colorName: "blue") }
            s.usage = ["A": Usage(fiveHour: 30, sevenDay: 50, error: nil),
                       "B": Usage(fiveHour: 30, sevenDay: 10, error: nil),
                       "C": Usage(fiveHour: 0, sevenDay: 100, error: nil),
                       "D": Usage(fiveHour: nil, sevenDay: nil, error: "not signed in")]
            equal(s.bestProfile()?.name, "B")
            equal(s.roomiestProfile()?.name, "B")
            s.usage = ["C": Usage(fiveHour: 0, sevenDay: 100, error: nil)]
            equal(s.bestProfile()?.name, "C")
            equal(s.roomiestProfile()?.name, nil)
        }

        // MARK: notification buttons

        test("alert categories: one set per profile, buttons in order") {
            equal(AlertAction.category(.threshold, "Personal"), "threshold|Personal")
            equal(AlertAction.category(.pace, nil), "pace|")
            let cats = AlertAction.categories(for: ["Default", "Work"])
            func actions(_ id: String) -> [String]? {
                cats.first { $0.identifier == id }?.actions.map(\.title)
            }
            equal(cats.count, 2 * 3 + 2)
            equal(actions("threshold|"), ["Mute Until Reset"])
            equal(actions("threshold|Work"), ["Open Work", "Mute Until Reset"])
            equal(actions("pace|Default"), ["Open Default", "Notify Me at Reset", "Mute Until Reset"])
            equal(actions("reset|Work"), ["Open Work"])
            equal(actions("reset|"), nil)
        }

        test("Mute Until Reset silences that limit until it resets") {
            let s = ProfileStore(live: false)
            s.alertMutedUntil = [:]
            let reset = Date().addingTimeInterval(1800)
            s.handleNotification(action: AlertAction.mute,
                                 info: ["profile": "Work", "limit": "5h", "reset": reset.timeIntervalSince1970])
            expect(s.isMuted("Work/5h"))
            expect(!s.isMuted("Work/7d"))
            expect(!s.isMuted("Work/5h", now: reset.addingTimeInterval(1)))
            // No reset known (or already past): one whole window.
            let now = Date()
            s.mute("Work/7d", until: now.addingTimeInterval(-10), window: ClaudeLimit.sevenDayWindow, now: now)
            equal(s.alertMutedUntil["Work/7d"], now.addingTimeInterval(ClaudeLimit.sevenDayWindow).timeIntervalSince1970)
            // Expired mutes are dropped.
            s.mute("Studio/5h", until: nil, window: 60, now: now.addingTimeInterval(ClaudeLimit.sevenDayWindow + 1))
            equal(s.alertMutedUntil["Work/7d"], nil)
            s.alertMutedUntil = [:]
        }

        test("Notify Me at Reset asks for a reset alert below the first level") {
            let s = ProfileStore(live: false)
            s.remindAtReset = [:]
            s.alertsEnabled = true
            s.alertWarn = 80
            let reset = Date().addingTimeInterval(3600)
            expect(!s.wantsResetAlert("Work/5h", value: 40, reset: reset))
            expect(s.wantsResetAlert("Work/5h", value: 85, reset: reset))
            s.handleNotification(action: AlertAction.remind,
                                 info: ["profile": "Work", "limit": "5h", "reset": reset.timeIntervalSince1970])
            expect(s.wantsResetAlert("Work/5h", value: 40, reset: reset))
            // Only for that window, and never for a reset that has passed.
            expect(!s.wantsResetAlert("Work/5h", value: 40, reset: reset.addingTimeInterval(5 * 3600)))
            expect(!s.wantsResetAlert("Work/5h", value: 90, reset: Date().addingTimeInterval(-1)))
            s.alertsEnabled = false
            expect(!s.wantsResetAlert("Work/5h", value: 90, reset: reset))
            s.alertsEnabled = true
            s.remindAtReset = [:]
        }

        test("alternative: the roomiest other profile, only with half its 5 hours left") {
            let s = ProfileStore(live: false)
            s.profiles = ["Work", "Personal"].map { Profile(name: $0, dataDir: "/tmp/\($0)", colorName: "blue") }
            s.usage = ["Work": Usage(fiveHour: 90, sevenDay: 50, error: nil),
                       "Personal": Usage(fiveHour: 20, sevenDay: 10, error: nil)]
            equal(s.alternative(to: "Work")?.name, "Personal")
            equal(s.alternative(to: "Personal"), nil)
            s.usage["Personal"] = Usage(fiveHour: 60, sevenDay: 10, error: nil)
            equal(s.alternative(to: "Work"), nil)
        }

        // MARK: health

        test("HealthCheck.parse reads lanes doctor --tsv, empty fields kept") {
            let tsv = "ok\tclaude\tClaude Desktop is installed\tVersion 1.2\t\n"
                + "warn\twatchdog\tThe watchdog isn't running\tWhy it matters.\twatchdog\n"
                + "fail\tlauncher:Client Acme\tClient Acme: launcher missing\t\tlauncher:Client Acme\n"
                + "bogus\tx\tUnknown status\t\t\n"
                + "ok\tshort\n"
                + "ok\tsetup\tLaunchers point at this copy of Lanes"
            let c = HealthCheck.parse(tsv: tsv)
            equal(c.map(\.id), ["claude", "watchdog", "launcher:Client Acme", "setup"])
            equal(c[0].detail, "Version 1.2")
            equal(c[0].fix, nil)
            equal(c[1].status, .warn)
            equal(c[1].fixTitle, "Fix")
            equal(c[2].status, .fail)
            equal(c[2].detail, "")
            equal(c[2].fix, "launcher:Client Acme")
            equal(c[2].fixTitle, "Recreate")
            equal(c[3].detail, "")
            equal(HealthCheck(id: "s", status: .warn, title: "", fix: "signin:Work").fixTitle, "Open")
            equal(HealthCheck(id: "x", status: .warn, title: "", fix: "something-new").fixTitle, nil)
        }

        test("healthNeedsAttention ignores choices and self-healing") {
            let s = ProfileStore(live: false)
            s.health = [HealthCheck(id: "login", status: .warn, title: ""),
                        HealthCheck(id: "clone:Work", status: .warn, title: ""),
                        HealthCheck(id: "claude", status: .ok, title: "")]
            equal(s.healthIssues.count, 2)
            expect(!s.healthNeedsAttention)
            s.health.append(HealthCheck(id: "watchdog", status: .warn, title: ""))
            expect(s.healthNeedsAttention)
        }

        test("Try-it actions parse, skipping unknown ones") {
            equal(TryAction.parse(" copy lanes claude --best | statusline | test-alert | settings status | settings nope | teleport "),
                  [.copy("lanes claude --best"), .statusLine, .testAlert, .settings(.status)])
            equal(TryAction.parse("copy"), [])
        }

        test("Changelog: try comments attach to their release, and stay out of the text") {
            let md = """
            <!-- format notes, before any release -->
            ## 0.10.0 — New things
            _2026-11-27_
            <!-- try: copy lanes claude work | statusline -->

            - **One** thing.

            ## 0.9.0 — Old things
            _2026-11-25_

            - Another.
            """
            let e = Changelog.parse(md)
            equal(e.map(\.version), ["0.10.0", "0.9.0"])
            equal(e[0].actions, [.copy("lanes claude work"), .statusLine])
            equal(e[1].actions, [])
            equal(e[0].blocks.count, 1)
            expect(e[0].date != nil)
        }

        test("CHANGELOG.md: every release parses, and try actions are all known") {
            let text = try String(contentsOfFile: "CHANGELOG.md", encoding: .utf8)
            let e = Changelog.parse(text)
            expect(!e.isEmpty)
            expect(e.allSatisfy { $0.date != nil && !$0.blocks.isEmpty }, "a release without a date or notes")
            let declared = text.components(separatedBy: "\n").filter { $0.hasPrefix("<!-- try:") }
                .map { $0.components(separatedBy: "|").count }.reduce(0, +)
            equal(e.map(\.actions.count).reduce(0, +), declared)
        }

        test("StatusLineState parses lanes statusline --tsv") {
            let tsv = "Default\ton\t/a/settings.json\nWork\tadded\t/b\nAcme\tother\t/c\nOld\tremoved\t/d\nBad\tinvalid\t/e\nshort\n"
            let s = StatusLineState.parse(tsv: tsv)
            equal(s.map(\.profile), ["Default", "Work", "Acme", "Old", "Bad"])
            equal(s.map(\.state), [.on, .on, .other, .off, .invalid])
            let store = ProfileStore(live: false)
            store.statusLine = s
            equal(store.statusLineOn.count, 2)
            equal(ProfileStore.joined(["A", "B", "C"]), "A, B and C")
            equal(store.statusLineSummary, "On for 2 of 5 profiles. Acme has its own. Can't read the settings of Bad.")
        }

        print(failures == 0 ? "unit tests: \(checks) checks passed" : "unit tests: \(failures) of \(checks) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
