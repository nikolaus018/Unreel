import XCTest
@testable import Unreel

@MainActor
final class LibraryTests: XCTestCase {
    private var library: LocalLibrary!

    override func setUp() async throws {
        let name = "test-library-\(UUID().uuidString).json"
        library = LocalLibrary(fileName: name)
    }

    func testKeywordsMatchWholeWordsIgnoringCaseAndAccents() {
        library.addKeyword("Reaction")
        library.addKeyword("café")
        XCTAssertTrue(library.matchesKeyword("My REACTION to the trailer"))
        XCTAssertTrue(library.matchesKeyword("Best cafe in town"))
        XCTAssertFalse(library.matchesKeyword("Chain reactions explained"), "only whole words")
        XCTAssertFalse(library.matchesKeyword("Totally unrelated"))
    }

    func testBlockedChannelsByIdOrName() {
        library.block(ChannelItem(id: "UC123", name: "Clickbait TV"))
        XCTAssertTrue(library.isBlocked(channelId: "UC123", name: nil))
        XCTAssertTrue(library.isBlocked(channelId: nil, name: "clickbait tv"))
        XCTAssertFalse(library.isBlocked(channelId: "UC999", name: "Other"))
        let v = VideoItem(id: "abc", title: "x", channelName: "Clickbait TV")
        XCTAssertFalse(library.allows(.video(v), hideWatched: false))
    }

    func testHideWatchedAndResume() {
        let v = VideoItem(id: "vid1", title: "Long video")
        library.updateProgress(v, position: 300, duration: 1000)
        XCTAssertEqual(library.resumePosition(for: "vid1"), 300)
        XCTAssertTrue(library.allows(.video(v), hideWatched: true))
        library.updateProgress(v, position: 950, duration: 1000)
        XCTAssertNil(library.resumePosition(for: "vid1"), "nearly finished videos start over")
        XCTAssertFalse(library.allows(.video(v), hideWatched: true))
        XCTAssertTrue(library.allows(.video(v), hideWatched: false))
        XCTAssertEqual(library.history.count, 1)
    }

    func testTakeoutImportAndExport() {
        let csv = """
        Channel Id,Channel Url,Channel Title
        UCaaa,http://www.youtube.com/channel/UCaaa,Alpha
        UCbbb,http://www.youtube.com/channel/UCbbb,"Beta, the Channel"

        """
        XCTAssertEqual(library.importSubscriptions(csv: csv), 2)
        XCTAssertEqual(library.importSubscriptions(csv: csv), 0, "no duplicates")
        XCTAssertEqual(library.subscriptions.map(\.name), ["Alpha", "Beta, the Channel"])
        XCTAssertTrue(library.exportSubscriptionsCSV().contains("\"Beta, the Channel\""))
    }

    func testSpeedPerChannel() {
        library.setSpeed(1.5, for: "UC1", defaultSpeed: 1)
        XCTAssertEqual(library.speed(for: "UC1"), 1.5)
        library.setSpeed(1, for: "UC1", defaultSpeed: 1)
        XCTAssertNil(library.speed(for: "UC1"), "the default speed isn't stored")
    }
}

final class CommunityTests: XCTestCase {
    func testRelativeAges() {
        XCTAssertEqual(LocalFeeds.age(of: "3 days ago"), 3 * 86_400)
        XCTAssertEqual(LocalFeeds.age(of: "Streamed 2 weeks ago"), 2 * 604_800)
        XCTAssertEqual(LocalFeeds.age(of: "vor 5 Stunden"), 5 * 3600)
        XCTAssertEqual(LocalFeeds.age(of: "vor 1 Monat"), 2_592_000)
        XCTAssertEqual(LocalFeeds.age(of: "il y a 2 ans"), 2 * 31_536_000)
        XCTAssertEqual(LocalFeeds.age(of: "10 minutes ago"), 600)
        XCTAssertEqual(LocalFeeds.age(of: nil), .infinity)
        XCTAssertLessThan(LocalFeeds.age(of: "1 hour ago"), LocalFeeds.age(of: "1 day ago"))
    }

    func testDeArrowPick() {
        let b = DeArrowClient.pick(titles: [(">Exact title", false, 0, false), ("Other", false, 5, false)],
                                   thumbnails: [(nil, true, 3, false)])
        XCTAssertEqual(b.title, "Exact title")
        XCTAssertNil(b.thumbnailTime, "original thumbnail wins")
        let down = DeArrowClient.pick(titles: [("Downvoted", false, -1, false)], thumbnails: [(12.5, false, 1, false)])
        XCTAssertNil(down.title)
        XCTAssertEqual(down.thumbnailTime, 12.5)
        let original = DeArrowClient.pick(titles: [("Same as YouTube", true, 4, false)], thumbnails: [])
        XCTAssertNil(original.title)
    }

    func testCommentParams() {
        // Matches what YouTube's web client sends for this video.
        XCTAssertEqual(InnerTube.commentParams(videoId: "dQw4w9WgXcQ"), "EgtkUXc0dzlXZ1hjUSoCCABQAQ==")
    }

    func testChannelSubscribedIgnoresFeaturedChannels() throws {
        // Shape of a signed-in MWEB channel page: a featured-channels shelf (not subscribed) comes
        // before the header's own state entity (subscribed).
        let json = """
        {"header":{"pageHeaderRenderer":{"content":{"pageHeaderViewModel":{"actions":{"flexibleActionsViewModel":{"actionsRows":[{"actions":[{"subscribeButtonViewModel":{"stateEntityStoreKey":"OWN"}}]}]}}}}}},
         "contents":{"shelf":{"compactChannelRenderer":{"subscribeButton":{"subscribeButtonRenderer":{"subscribed":false}}}}},
         "frameworkUpdates":{"entityBatchUpdate":{"mutations":[
           {"entityKey":"OTHER","payload":{"subscriptionStateEntity":{"subscribed":false}}},
           {"entityKey":"OWN","payload":{"subscriptionStateEntity":{"subscribed":true}}}]}}}
        """
        let root = try J(data: Data(json.utf8))
        XCTAssertEqual(Parser.channelSubscribed(root), true)
    }

    func testDurationSeconds() {
        XCTAssertEqual(AppModel.seconds(fromDuration: "1:02:03"), 3723)
        XCTAssertEqual(AppModel.seconds(fromDuration: "4:05"), 245)
        XCTAssertNil(AppModel.seconds(fromDuration: "LIVE"))
    }
}
