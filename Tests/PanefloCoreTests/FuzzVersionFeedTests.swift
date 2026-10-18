import Foundation
import Testing
@testable import PanefloCore

/// SemanticVersion / GitHubRelease / UpdateCheck / ReleaseNotes / UpdateSchedule fuzz and law tests.
struct FuzzVersionFeedTests {
    private static let alphabet = Array("0123456789.-+vV \t\n_abAZ\u{e9}\u{663}\u{ff11}\u{200d}\u{1f600}")

    private static func randomText(_ rng: inout FuzzRandom) -> String {
        String((0..<rng.int(0...22)).map { _ in alphabet[rng.int(0...alphabet.count - 1)] })
    }

    /// Well-formed versions: no leading-hyphen pre-release identifiers (see the disabled BUG tests).
    private static func randomVersion(_ rng: inout FuzzRandom) -> SemanticVersion {
        var pre: [String] = []
        if rng.chance(0.5) {
            for _ in 0..<rng.int(1...3) {
                pre.append(rng.chance(0.5) ? String(rng.int(0...30)) : rng.pick(["alpha", "beta", "rc", "Z", "x-1", "a0", "b"]))
            }
        }
        return SemanticVersion(major: rng.int(0...3), minor: rng.int(0...3), patch: rng.int(0...3), preRelease: pre)
    }

    /// Independent semver 2.0.0 comparison (numeric identifiers compared as digit strings, so arbitrary length).
    private static func referenceLess(_ a: SemanticVersion, _ b: SemanticVersion) -> Bool {
        let core: [(Int, Int)] = [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)]
        for (x, y) in core where x != y { return x < y }
        if a.preRelease.isEmpty { return false }
        if b.preRelease.isEmpty { return true }
        func numeric(_ s: String) -> Bool { s.allSatisfy { $0.isASCII && $0.isNumber } }
        for (x, y) in zip(a.preRelease, b.preRelease) where x != y {
            switch (numeric(x), numeric(y)) {
            case (true, true): return x.count != y.count ? x.count < y.count : x < y
            case (true, false): return true
            case (false, true): return false
            case (false, false): return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8))
            }
        }
        return a.preRelease.count < b.preRelease.count
    }

    @Test func parsingRandomStringsNeverCrashesAndRoundTrips() {
        var rng = FuzzRandom(seed: 2024)
        var parsed = 0
        for _ in 0..<20_000 {
            let text = Self.randomText(&rng)
            guard let version = SemanticVersion(text) else { continue }
            parsed += 1
            #expect(SemanticVersion(version.description) == version, "round trip failed for \(text.debugDescription)")
        }
        #expect(parsed > 100, "generator never produced a version")
        for text in ["", " ", "v", "V1", "1.2.3.4", "-1", "1.-2", "1..2", "1.0.0-", "1.0.0-.", "1.0.0+", "+", "9999999999", "123456789", "1.0.0-01", "v1.0.0+build.5", " 1.2 ", "1.0.0-alpha..1"] {
            _ = SemanticVersion(text)
        }
    }

    @Test func orderingIsATotalOrderConsistentWithEqualityAndSemver() {
        for seed in UInt64(0)..<300 {
            var rng = FuzzRandom(seed: seed)
            let pool = (0..<40).map { _ in Self.randomVersion(&rng) }
            for a in pool {
                #expect(!(a < a))
                for b in pool {
                    let lt = a < b, gt = b < a, eq = a == b
                    #expect((lt ? 1 : 0) + (gt ? 1 : 0) + (eq ? 1 : 0) == 1, "seed \(seed): trichotomy broken for \(a) vs \(b)")
                    #expect(lt == Self.referenceLess(a, b), "seed \(seed): \(a) < \(b) disagrees with semver")
                }
            }
            for _ in 0..<400 {
                let a = rng.pick(pool), b = rng.pick(pool), c = rng.pick(pool)
                if a < b && b < c { #expect(a < c, "seed \(seed): transitivity \(a) \(b) \(c)") }
            }
            let sorted = pool.sorted()
            for pair in zip(sorted, sorted.dropFirst()) { #expect(!(pair.1 < pair.0), "seed \(seed): sort unstable") }
        }
    }

    @Test
    func hyphenPrefixedNumericLookalikesKeepTrichotomy() {
        let a = SemanticVersion("1.0.0--1"), b = SemanticVersion("1.0.0--01")
        #expect(a != nil && b != nil)
        guard let a, let b else { return }
        #expect((a < b) || (b < a) || (a == b))
        // semver: "-1" is alphanumeric, so it sorts after the numeric identifier 5.
        if let numeric = SemanticVersion("1.0.0-5"), let hyphen = SemanticVersion("1.0.0--1") { #expect(numeric < hyphen) }
    }

    @Test
    func hugeNumericPreReleaseIdentifiersCompareNumerically() {
        let small = SemanticVersion("1.0.0-99999999999999999999"), big = SemanticVersion("1.0.0-100000000000000000000")
        #expect(small != nil && big != nil)
        if let small, let big { #expect(small < big) }
    }

    private func release(tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: nil, body: "notes", htmlURL: URL(string: "https://example.invalid/r")!, draft: draft,
                      prerelease: prerelease, publishedAt: nil,
                      assets: assets.map { .init(name: $0, downloadURL: URL(string: "https://example.invalid/\($0)")!, size: 10) })
    }

    @Test func updateDecisionNeverOffersDowngradesDraftsOrPreReleases() {
        for seed in UInt64(0)..<500 {
            var rng = FuzzRandom(seed: seed)
            let current = Self.randomVersion(&rng)
            let latest = Self.randomVersion(&rng)
            let tag = (rng.chance(0.5) ? "v" : "") + latest.description
            let rel = release(tag: rng.chance(0.05) ? Self.randomText(&rng) : tag, draft: rng.chance(0.15), prerelease: rng.chance(0.15),
                              assets: rng.chance(0.85) ? ["Paneflo-\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag).zip", "source.zip"] : ["other.zip"])
            let skipped: String? = rng.chance(0.5) ? latest.description : nil
            for manual in [true, false] {
                guard let decision = try? UpdateCheck.decide(rel, current: current, skipped: skipped, manual: manual) else { continue }
                switch decision {
                case .available(let update):
                    #expect(!rel.draft && !rel.prerelease && !update.version.isPreRelease, "seed \(seed): offered a draft or pre-release")
                    #expect(update.version > current, "seed \(seed): offered \(update.version) over current \(current)")
                    #expect(update.asset.name == GitHubRelease.assetName(for: update.versionString), "seed \(seed): wrong asset")
                    if !manual, let skipped { #expect(!UpdateCheck.isSameVersion(skipped, update.versionString), "seed \(seed): offered skipped version automatically") }
                case .skipped(let version):
                    #expect(!manual && skipped != nil && UpdateCheck.isSameVersion(skipped!, version), "seed \(seed)")
                case .upToDate:
                    break
                }
                if manual, !rel.draft, !rel.prerelease, let v = rel.version, !v.isPreRelease, v > current, rel.appAsset != nil {
                    if case .available = decision {} else { fail("seed \(seed): manual check hid an eligible release") }
                }
            }
        }
        var symmetryRNG = FuzzRandom(seed: 77)
        for _ in 0..<200 {
            var rng = symmetryRNG
            _ = symmetryRNG.next()
            let a = Self.randomText(&rng), b = Self.randomText(&rng)
            #expect(UpdateCheck.isSameVersion(a, b) == UpdateCheck.isSameVersion(b, a))
        }
    }

    @Test func releaseDecodeSurvivesMutatedJSON() throws {
        let base = try #require(JSONSerialization.jsonObject(with: Data(releaseFixtureJSON.utf8)) as? [String: Any])
        #expect((try? GitHubRelease.decode(Data(releaseFixtureJSON.utf8))) != nil)
        let keys = Array(base.keys) + ["assets.name", "assets.size", "assets.browser_download_url", "assets.digest", "assets.state"]
        var decoded = 0
        for seed in UInt64(0)..<600 {
            var rng = FuzzRandom(seed: seed)
            var object = base
            for _ in 0..<rng.int(1...4) {
                let key = rng.pick(keys)
                let replacement: Any = rng.pick([NSNull(), 5, "x", true, [] as [Any], [String: Any](), String(repeating: "A", count: 100_000), -1.5e300, ["nested": ["deeper": [1, 2]]]])
                if key.hasPrefix("assets."), var assets = object["assets"] as? [[String: Any]], !assets.isEmpty {
                    let field = String(key.dropFirst(7))
                    switch rng.int(0...2) {
                    case 0: assets[0][field] = nil
                    case 1: assets[0][field] = replacement
                    default: assets.append(assets[0])
                    }
                    object["assets"] = assets
                } else if rng.chance(0.5) { object[key] = nil } else { object[key] = replacement }
            }
            var data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
            if rng.chance(0.3), !data.isEmpty { // byte-level damage
                switch rng.int(0...2) {
                case 0: data = data.prefix(rng.int(0...data.count))
                case 1: data[rng.int(0...data.count - 1)] = UInt8(rng.int(0...255))
                default: data.insert(UInt8(rng.int(0...255)), at: rng.int(0...data.count))
                }
            }
            if let release = try? GitHubRelease.decode(data) {
                decoded += 1
                if let sha = release.assets.compactMap(\.sha256).first { #expect(sha.count == 64 && sha.allSatisfy(\.isHexDigit) && sha == sha.lowercased()) }
                if let app = release.appAsset { #expect(app.name == GitHubRelease.assetName(for: release.versionString)) }
                _ = try? UpdateCheck.decide(release, current: SemanticVersion(major: 0, minor: 0, patch: 1), skipped: nil, manual: false)
            }
        }
        #expect(decoded > 50, "mutation corpus never decoded")
    }

    @Test func oneBadAssetDoesNotHideTheOthersAndDigestsAreStrict() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(releaseFixtureJSON.utf8)) as? [String: Any])
        var assets = try #require(object["assets"] as? [[String: Any]])
        assets.insert(["name": 5, "size": "big"], at: 0)
        assets.append(["garbage": true])
        object["assets"] = assets
        let release = try GitHubRelease.decode(JSONSerialization.data(withJSONObject: object))
        #expect(release.appAsset?.name == "Paneflo-0.0.15.zip")
        let url = URL(string: "https://example.invalid/a")!
        for (digest, valid) in [("sha256:" + String(repeating: "a", count: 64), true), ("SHA256:" + String(repeating: "A", count: 64), true),
                                ("sha256:" + String(repeating: "a", count: 63), false), ("sha256:" + String(repeating: "g", count: 64), false),
                                ("sha1:" + String(repeating: "a", count: 40), false), ("", false), ("sha256:", false)] {
            let asset = GitHubRelease.Asset(name: "n", downloadURL: url, size: 1, digest: digest)
            #expect((asset.sha256 != nil) == valid, "digest \(digest.prefix(12)) accepted=\(asset.sha256 != nil)")
        }
        let renamed = self.release(tag: "v1.0.0", assets: ["Paneflo-1.0.0.zip.bak", "paneflo-1.0.0.zip", "Paneflo-1.0.1.zip"])
        #expect(renamed.appAsset == nil)
    }

    @Test func releaseNotesRandomMarkdownNeverTrapsAndStopsAtInstall() {
        let fragments = ["## Fixed", "### Install", "###   install  ", "# INSTALL", "- bullet", "* star", "+ plus", "wrapped text", "", "   ", "\u{1f916} Generated", "####", "#", "- ", "**bold** `code`", String(repeating: "x", count: 5000)]
        for seed in UInt64(0)..<400 {
            var rng = FuzzRandom(seed: seed)
            var lines = (0..<rng.int(0...40)).map { _ in rng.pick(fragments) }
            let sentinel = "SENTINEL-AFTER-INSTALL"
            if rng.chance(0.5) {
                lines.removeAll { $0.lowercased().contains("install") }
                lines += ["### Install", sentinel, "- " + sentinel]
            }
            let blocks = ReleaseNotes.blocks(lines.joined(separator: rng.chance(0.5) ? "\n" : "\r\n"))
            let hasInstall = lines.contains("### Install")
            for block in blocks {
                switch block {
                case .heading(let level, let text): #expect(level >= 2 && !text.isEmpty, "seed \(seed)")
                    #expect(!(hasInstall && text.contains(sentinel)))
                case .bullet(let text), .paragraph(let text): #expect(!(hasInstall && text.contains(sentinel)), "seed \(seed): content after Install heading")
                }
            }
        }
    }

    @Test
    func releaseNotesHandleOddLineEndings() {
        for markdown in ["- fixed\r\r\n### Install\nSECRET text", "- fixed\r### Install\rSECRET text"] {
            #expect(ReleaseNotes.blocks(markdown) == [.bullet("fixed")], "\(markdown.debugDescription)")
        }
    }

    @Test func scheduleIsMonotoneOnceCheckIsDue() {
        for seed in UInt64(0)..<300 {
            var rng = FuzzRandom(seed: seed)
            let last = Date(timeIntervalSinceReferenceDate: rng.double(1e8...1e9))
            for atLaunch in [true, false] {
                var due = false
                var offset = -UpdateSchedule.clockSlack
                while offset < 3 * UpdateSchedule.interval {
                    offset += rng.double(1...20_000)
                    let now = last.addingTimeInterval(offset)
                    let isDue = UpdateSchedule.isDue(lastCheck: last, now: now, atLaunch: atLaunch)
                    if due { #expect(isDue, "seed \(seed): isDue flipped back at +\(offset)s") }
                    due = due || isDue
                    let next = UpdateSchedule.nextCheck(lastCheck: last, now: now)
                    #expect(next >= now || !UpdateSchedule.isDue(lastCheck: last, now: now, atLaunch: false), "seed \(seed): next check in the past")
                }
                #expect(due, "never due")
            }
            #expect(UpdateSchedule.isDue(lastCheck: last, now: last.addingTimeInterval(-3600), atLaunch: false), "clock set back must recheck")
        }
    }
}
