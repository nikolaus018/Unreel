import XCTest
@testable import Unreel

/// Parses real InnerTube (MWEB) responses captured in November 2026.
final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> J {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try J(data: Data(contentsOf: url))
    }

    func testSearchResults() throws {
        let page = Parser.feed(try fixture("search"), hideShorts: true)
        let videos = page.items.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        XCTAssertGreaterThan(videos.count, 5)
        XCTAssertFalse(videos.contains { $0.isShort }, "Shorts must be filtered")
        let first = try XCTUnwrap(videos.first)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertNotNil(first.channelName)
        XCTAssertNotNil(first.channelId)
        XCTAssertNotNil(first.duration)
        XCTAssertTrue(page.items.contains { if case .channel = $0 { return true } else { return false } })
        XCTAssertNotNil(page.continuation)
    }

    func testShortsIncludedWhenNotHidden() throws {
        let shown = Parser.feed(try fixture("search"), hideShorts: false)
        let hidden = Parser.feed(try fixture("search"), hideShorts: true)
        XCTAssertGreaterThan(shown.items.count, hidden.items.count)
    }

    func testWatchDetails() throws {
        let w = Parser.watch(try fixture("next"), videoId: "xEwMuwdXiJw", hideShorts: true)
        XCTAssertEqual(w.title, "The only iPhone Duo review you need.")
        XCTAssertNotNil(w.views)
        XCTAssertNotNil(w.date)
        XCTAssertNotNil(w.likes)
        XCTAssertFalse((w.description ?? "").isEmpty)
        XCTAssertNotNil(w.channel?.id)
        XCTAssertNotNil(w.channel?.avatar)
        XCTAssertGreaterThan(w.related.count, 5)
        XCTAssertNotNil(w.relatedContinuation)
        XCTAssertNotNil(w.commentsToken)
    }

    func testComments() throws {
        let page = Parser.comments(try fixture("comments"))
        XCTAssertGreaterThan(page.comments.count, 10)
        XCTAssertTrue(page.comments.contains { $0.isPinned })
        XCTAssertFalse(page.comments[0].text.isEmpty)
        XCTAssertNotNil(page.continuation)
    }

    func testChannelHeader() throws {
        let page = Parser.channelPage(try fixture("channel"), id: "UCBJycsmduvYEL83R_U4JriQ")
        XCTAssertEqual(page.channel.name, "Marques Brownlee")
        XCTAssertEqual(page.handle, "@mkbhd")
        XCTAssertNotNil(page.channel.avatar)
        XCTAssertTrue(page.tabs.contains { $0.title == "Videos" })
    }

    func testSAPISIDHash() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "SAPISID", .value: "abc", .domain: ".youtube.com", .path: "/"]))
        let header = try XCTUnwrap(InnerTube.authorization([cookie]))
        XCTAssertTrue(header.hasPrefix("SAPISIDHASH "))
        XCTAssertEqual(header.split(separator: "_").last?.count, 40)   // SHA-1 hex
        XCTAssertNil(InnerTube.authorization([]))
    }
}

final class TimestampTests: XCTestCase {
    @MainActor func testParse() {
        XCTAssertEqual(AppModel.parseTimestamp("90"), 90)
        XCTAssertEqual(AppModel.parseTimestamp("90s"), 90)
        XCTAssertEqual(AppModel.parseTimestamp("1m30s"), 90)
        XCTAssertEqual(AppModel.parseTimestamp("1h2m3s"), 3723)
        XCTAssertEqual(AppModel.parseTimestamp(nil), 0)
    }
}

/// What VoiceOver reads for video cells.
final class AccessibilityTextTests: XCTestCase {
    func testSpokenDuration() {
        XCTAssertNotNil(VideoItem.spokenDuration("12:05"))
        XCTAssertNotEqual(VideoItem.spokenDuration("1:02:03"), VideoItem.spokenDuration("2:03"))
        XCTAssertNil(VideoItem.spokenDuration("LIVE"))
        XCTAssertNil(VideoItem.spokenDuration("1:2:3:4"))
    }

    func testDescriptionSkipsDurationForLive() {
        let live = VideoItem(id: "x", title: "Launch", channelName: "NASA", duration: "1:00", isLive: true)
        XCTAssertTrue(live.accessibilityDescription.hasPrefix("Launch, Live, NASA"))
        XCTAssertEqual(live.accessibilityDescription, "Launch, Live, NASA")
    }
}
