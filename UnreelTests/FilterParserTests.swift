import WebKit
import XCTest
@testable import Unreel

final class FilterParserTests: XCTestCase {

    private func parse(_ text: String, trusted: Bool = true) -> ParseResult {
        var r = ParseResult()
        FilterParser.parse(text, trusted: trusted, into: &r)
        r.finalize()
        return r
    }

    func testHostAnchorPattern() {
        XCTAssertEqual(FilterParser.urlFilter(fromPattern: "||doubleclick.net^"), "^[^:]+://+([^:/]+\\.)?doubleclick\\.net[/:?&=]")
        XCTAssertEqual(FilterParser.urlFilter(fromPattern: "/pagead/*.js|"), "/pagead/.*\\.js$")
        XCTAssertNil(FilterParser.urlFilter(fromPattern: "||a.com|b"))
        XCTAssertNil(FilterParser.urlFilter(fromPattern: "ad"))   // too generic
    }

    func testNetworkOptions() throws {
        let r = parse("||ads.example.com^$script,third-party\n@@||ok.example.com^$image")
        XCTAssertEqual(r.blocks.count, 1)
        XCTAssertEqual(r.allows.count, 1)
        let trigger = try XCTUnwrap(r.blocks.first?["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["resource-type"] as? [String], ["script"])
        XCTAssertEqual(trigger["load-type"] as? [String], ["third-party"])
    }

    func testDomainRelevance() {
        // Only for another site: dropped. For YouTube: kept with if-domain.
        let r = parse("||tracker.com^$domain=news.com\n||yt-ad.com^$domain=youtube.com|news.com")
        XCTAssertEqual(r.blocks.count, 1)
        let trigger = r.blocks.first?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["if-domain"] as? [String], ["*youtube.com"])
    }

    func testUnsupportedOptionsAreSkipped() {
        let r = parse("||example.com^$removeparam=utm\n||example.org^$csp=script-src 'none'")
        XCTAssertTrue(r.blocks.isEmpty)
    }

    func testCosmeticOnlyForYouTube() {
        let r = parse("example.com##.ad\nm.youtube.com##ytm-promoted-video-renderer\n##.generic-ad\nyoutube.com#@#.keep")
        XCTAssertEqual(r.page.cosmetic.map(\.s), ["ytm-promoted-video-renderer"])
    }

    func testScriptletParsing() throws {
        let line = "m.youtube.com,www.youtube.com##+js(json-prune-fetch-response, adPlacements adSlots, , propsToMatch, /\\/player(\\?|$)/)"
        let r = parse(line)
        let s = try XCTUnwrap(r.page.scriptlets.first)
        XCTAssertEqual(s.n, "json-prune-fetch-response")
        XCTAssertEqual(s.a, ["adPlacements adSlots", "", "propsToMatch", "/\\/player(\\?|$)/"])
        XCTAssertEqual(s.d, ["m.youtube.com", "www.youtube.com"])
    }

    func testScriptletAliasesAndEscapes() throws {
        let r = parse("youtube.com##+js(set, ytInitialPlayerResponse.adSlots, undefined)\nyoutube.com##+js(trusted-rpfr, '\"adSlots\"', '\"no_ads\"', player?)")
        XCTAssertEqual(r.page.scriptlets.map(\.n), ["set-constant", "trusted-replace-fetch-response"])
        XCTAssertEqual(r.page.scriptlets[1].a, ["\"adSlots\"", "\"no_ads\"", "player?"])
    }

    func testTrustedScriptletsNeedTrustedList() {
        let r = parse("youtube.com##+js(trusted-rpfr, a, b)", trusted: false)
        XCTAssertTrue(r.page.scriptlets.isEmpty)
    }

    func testScriptletException() {
        let r = parse("youtube.com##+js(set, a.b, undefined)\nyoutube.com#@#+js(set, a.b, undefined)")
        XCTAssertTrue(r.page.scriptlets.isEmpty)
    }

    func testReplaceRule() throws {
        let r = parse("||youtube.com/youtubei/v1/get_watch?$xhr,1p,replace=/\"adPlacements\"/\"no_ads\"/")
        let rule = try XCTUnwrap(r.page.replaces.first)
        XCTAssertEqual(rule.f, "\"adPlacements\"")
        XCTAssertEqual(rule.r, "\"no_ads\"")
        XCTAssertTrue(r.blocks.isEmpty)
    }

    func testPreprocessor() {
        let text = """
        !#if env_firefox
        m.youtube.com##.firefox-only
        !#else
        m.youtube.com##.everyone-else
        !#endif
        !#if env_safari && !env_chromium
        m.youtube.com##.safari
        !#endif
        """
        XCTAssertEqual(parse(text).page.cosmetic.map(\.s), [".everyone-else", ".safari"])
    }

    func testHostsFormat() {
        let r = parse("# comment\n0.0.0.0 ads.example.com\n127.0.0.1 localhost")
        XCTAssertEqual(r.blocks.count, 1)
    }

    func testBadfilter() {
        let r = parse("||example.com^$script\n||example.com^$script,badfilter")
        XCTAssertTrue(r.blocks.isEmpty, "a badfilter listed after the rule still cancels it")
    }

    /// Parses the bundled lists and compiles them with WebKit, the same way the app does on first launch.
    @MainActor
    func testBundledListsCompile() async throws {
        var result = ParseResult()
        var parsedLists = 0
        for list in FilterCatalog.lists where list.defaultEnabled {
            guard let url = Bundle(for: PlayerController.self).url(forResource: list.id, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            FilterParser.parse(text, trusted: list.trusted, into: &result)
            parsedLists += 1
        }
        result.finalize()
        XCTAssertEqual(parsedLists, 6)
        XCTAssertGreaterThan(result.blocks.count, 20_000)
        XCTAssertFalse(result.page.scriptlets.isEmpty, "uBlock's YouTube scriptlets should be picked up")
        XCTAssertTrue(result.page.scriptlets.contains { $0.n == "json-prune" || $0.n == "set-constant" })

        let start = Date()
        let output = await ContentBlockerCompiler.compile(blocks: FilterCatalog.builtInNetworkRules + result.blocks,
                                                          allows: result.allows, prefix: "unreel-test")
        print("Compiled \(result.blocks.count) blocks + \(result.allows.count) allows into \(output.lists.count) lists in \(Date().timeIntervalSince(start))s, dropped \(output.droppedRules); cosmetic \(result.page.cosmetic.count), scriptlets \(result.page.scriptlets.count), replaces \(result.page.replaces.count), skipped \(result.skipped)")
        XCTAssertFalse(output.lists.isEmpty)
        XCTAssertLessThan(output.droppedRules, 50)
        await ContentBlockerCompiler.removeAll(except: [])
    }
}
