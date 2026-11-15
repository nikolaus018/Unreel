import Foundation

/// Turns InnerTube (MWEB) responses into models. Written to tolerate the many renderer variants
/// YouTube uses: unknown shapes are skipped rather than failing the whole page.
enum Parser {

    // MARK: Feeds

    /// Containers that never hold feed content (or hold duplicates of it).
    private static let skippedKeys: Set<String> = [
        "playerOverlays", "topbar", "menu", "engagementPanels", "frameworkUpdates", "thumbnailOverlays",
        "header", "pivotBar", "responseContext", "microformat", "metadata", "trackingParams",
        "slimVideoMetadataSectionRenderer", "videoMetadataCarouselViewModel", "sheetViewModel",
        "inlinePlaybackEndpoint", "richThumbnail",
    ]

    static func feed(_ root: J, hideShorts: Bool) -> FeedPage {
        var page = FeedPage()
        var seen = Set<String>()

        func add(_ item: FeedItem) {
            if seen.insert(item.id).inserted { page.items.append(item) }
        }

        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                for (key, value) in d {
                    if skippedKeys.contains(key) { continue }
                    let j = J(value)
                    switch key {
                    case "videoWithContextRenderer", "compactVideoRenderer", "videoRenderer", "gridVideoRenderer",
                         "playlistVideoRenderer", "playlistPanelVideoRenderer":
                        if let v = video(j), !(hideShorts && v.isShort) { add(.video(v)) }
                    case "reelItemRenderer", "shortsLockupViewModel":
                        if !hideShorts, let v = short(j, key: key) { add(.video(v)) }
                    case "reelShelfRenderer":
                        if !hideShorts { walk(value) }
                    case "lockupViewModel":
                        if let item = lockup(j) {
                            if case .video(let v) = item, hideShorts && v.isShort { break }
                            add(item)
                        }
                    case "channelRenderer", "compactChannelRenderer", "gridChannelRenderer", "channelListItemRenderer":
                        if let c = channel(j) { add(.channel(c)) }
                    case "compactPlaylistRenderer", "playlistRenderer", "gridPlaylistRenderer", "compactRadioRenderer", "radioRenderer":
                        if let p = playlist(j) { add(.playlist(p)) }
                    case "continuationItemRenderer":
                        if let token = j.first("token").string { page.continuation = token }
                    case "continuationCommand":
                        if page.continuation == nil, let token = j["token"].string { page.continuation = token }
                    default:
                        walk(value)
                    }
                }
            } else if let a = node as? [Any] {
                a.forEach(walk)
            }
        }

        // Keep document order: iterate dictionaries in a stable way by walking ordered containers.
        walkOrdered(root.value, visit: walk)
        return page
    }

    /// JSONSerialization dictionaries are unordered; YouTube puts the content under a few known
    /// keys, so we walk those first to preserve the visual order of sections.
    private static func walkOrdered(_ node: Any?, visit: (Any) -> Void) {
        guard let node else { return }
        visit(node)
    }

    // MARK: Item renderers

    static func video(_ r: J) -> VideoItem? {
        guard let id = r["videoId"].string ?? r["navigationEndpoint"]["watchEndpoint"]["videoId"].string else { return nil }
        let title = r["headline"].text ?? r["title"].text ?? ""
        let byline = [r["shortBylineText"], r["longBylineText"], r["ownerText"]].first { $0.exists } ?? J(nil)
        let channelId = byline["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            ?? r["channelThumbnail"]["channelThumbnailWithLinkRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
        let avatar = r["channelThumbnail"]["channelThumbnailWithLinkRenderer"]["thumbnail"].thumbnailURL
            ?? r["channelThumbnail"].thumbnailURL
            ?? r["channelThumbnailSupportedRenderers"]["channelThumbnailWithLinkRenderer"]["thumbnail"].thumbnailURL
        let overlayTime = r["thumbnailOverlays"].array.first { $0["thumbnailOverlayTimeStatusRenderer"].exists }?["thumbnailOverlayTimeStatusRenderer"]
        let duration = r["lengthText"].text ?? overlayTime?["text"].text
        let isLive = overlayTime?["style"].string == "LIVE"
            || r["badges"].array.contains { ($0["metadataBadgeRenderer"]["style"].string ?? "").contains("LIVE") }
        let isShort = r["navigationEndpoint"]["reelWatchEndpoint"].exists || overlayTime?["style"].string == "SHORTS"
        return VideoItem(
            id: id,
            title: title,
            channelName: byline.text,
            channelId: channelId,
            channelAvatar: avatar,
            duration: isLive ? nil : duration,
            views: r["shortViewCountText"].text ?? r["viewCountText"].text,
            published: r["publishedTimeText"].text,
            isLive: isLive,
            isShort: isShort,
            progress: r["thumbnailOverlays"].array.first { $0["thumbnailOverlayResumePlaybackRenderer"].exists }?["thumbnailOverlayResumePlaybackRenderer"]["percentDurationWatched"].double.map { $0 / 100 })
    }

    static func short(_ r: J, key: String) -> VideoItem? {
        if key == "reelItemRenderer" {
            guard let id = r["videoId"].string else { return nil }
            return VideoItem(id: id, title: r["headline"].text ?? "", views: r["viewCountText"].text, isShort: true)
        }
        let id = r["onTap"]["innertubeCommand"]["reelWatchEndpoint"]["videoId"].string
            ?? r["entityId"].string?.replacingOccurrences(of: "shorts-shelf-item-", with: "")
        guard let id, !id.isEmpty else { return nil }
        return VideoItem(id: id, title: r["overlayMetadata"]["primaryText"]["content"].string ?? "",
                         views: r["overlayMetadata"]["secondaryText"]["content"].string, isShort: true)
    }

    static func lockup(_ r: J) -> FeedItem? {
        guard let id = r["contentId"].string else { return nil }
        let meta = r["metadata"]["lockupMetadataViewModel"]
        let title = meta["title"]["content"].string ?? ""
        let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        let parts = rows.flatMap { $0["metadataParts"].array.compactMap { $0["text"]["content"].string } }
        let avatarVM = meta["image"]
        let avatar = avatarVM.first("avatarViewModel")["image"].thumbnailURL
        let channelId = avatarVM.first("browseEndpoint")["browseId"].string
        switch r["contentType"].string {
        case "LOCKUP_CONTENT_TYPE_VIDEO", "LOCKUP_CONTENT_TYPE_SHORTS":
            let badge = r["contentImage"].first("thumbnailBadgeViewModel")
            let badgeText = badge["text"].string
            let isLive = (badge["badgeStyle"].string ?? "").contains("LIVE") || badgeText == "LIVE"
            let isShort = r["contentType"].string == "LOCKUP_CONTENT_TYPE_SHORTS" || r["rendererContext"].first("reelWatchEndpoint").exists
            let progress = r["contentImage"].first("thumbnailOverlayProgressBarViewModel")["startPercent"].double
            // Parts are [channel, views, published]; channel-less lockups (on channel pages) drop the first.
            let hasChannel = parts.count >= 3 || (parts.first.map { !$0.contains("view") && !$0.contains("ago") } ?? false)
            let channel = hasChannel ? parts.first : nil
            let rest = hasChannel ? Array(parts.dropFirst()) : parts
            var v = VideoItem(id: id, title: title, channelName: channel, channelId: channelId, channelAvatar: avatar,
                              duration: isLive ? nil : badgeText, views: rest.first, published: rest.count > 1 ? rest[1] : nil,
                              isLive: isLive, isShort: isShort)
            v.progress = progress.map { $0 / 100 }
            return .video(v)
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_ALBUM":
            let thumb = r["contentImage"].first("image").thumbnailURL
            let count = r["contentImage"].first("thumbnailBadgeViewModel")["text"].string
            return .playlist(PlaylistItem(id: id, title: title, thumbnail: thumb, count: count, owner: parts.first))
        default:
            return nil
        }
    }

    static func channel(_ r: J) -> ChannelItem? {
        guard let id = r["channelId"].string ?? r["navigationEndpoint"]["browseEndpoint"]["browseId"].string else { return nil }
        let name = r["title"].text ?? r["displayName"].text ?? ""
        let subtitle = r["subscriberCountText"].text ?? r["videoCountText"].text
        return ChannelItem(id: id, name: name, avatar: r["thumbnail"].thumbnailURL, subtitle: subtitle)
    }

    static func playlist(_ r: J) -> PlaylistItem? {
        guard let id = r["playlistId"].string ?? r["navigationEndpoint"]["watchEndpoint"]["playlistId"].string else { return nil }
        let thumb = r["thumbnail"].thumbnailURL ?? r["thumbnails"][0].thumbnailURL
            ?? r["thumbnailRenderer"].first("thumbnail").thumbnailURL
        return PlaylistItem(id: id, title: r["title"].text ?? "",
                            thumbnail: thumb,
                            count: r["videoCountShortText"].text ?? r["videoCountText"].text ?? r["thumbnailText"].text,
                            owner: r["shortBylineText"].text ?? r["longBylineText"].text)
    }

    // MARK: Watch page

    static func watch(_ root: J, videoId: String, hideShorts: Bool) -> WatchDetails {
        let header = root.first("videoDescriptionHeaderRenderer")
        let owner = root.first("slimOwnerRenderer")
        let metaVM = root.first("videoMetadataViewModel")
        let infocards = root.first("videoDescriptionInfocardsSectionRenderer")

        var details = WatchDetails(videoId: videoId, title: header["title"].text ?? metaVM["title"]["content"].string ?? "")
        details.views = header["views"].text
        details.date = header["publishDate"].text
        details.likes = header["factoid"].array.first?.first("value").text
        let body = root.first("expandableVideoDescriptionBodyRenderer")
        details.descriptionLinks = textLinks(body["attributedDescriptionBodyText"]["commandRuns"], videoId: videoId)
        details.description = body["attributedDescriptionBodyText"]["content"].string
            ?? body["attributedDescription"]["content"].string
            ?? body["descriptionBodyText"].text

        let channelId = owner["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            ?? header["channelNavigationEndpoint"]["browseEndpoint"]["browseId"].string
        if let channelId {
            details.channel = ChannelItem(
                id: channelId,
                name: owner["title"].text ?? header["channel"].text ?? "",
                avatar: owner["thumbnail"].thumbnailURL ?? header["channelThumbnail"].thumbnailURL,
                subtitle: infocards["sectionSubtitle"].text ?? owner["expandedSubtitle"].text.map { "\($0) subscribers" })
        }

        let results = root["contents"]["singleColumnWatchNextResults"]["results"]["results"]["contents"]
        let related = feed(results, hideShorts: hideShorts)
        details.related = related.items.compactMap { if case .video(let v) = $0, v.id != videoId { return v } else { return nil } }
        details.relatedContinuation = related.continuation

        for panel in root["engagementPanels"].array {
            let p = panel["engagementPanelSectionListRenderer"]
            let isComments = (p["panelIdentifier"].string ?? "").contains("comment")
                || p["header"]["engagementPanelTitleHeaderRenderer"]["title"].text == "Comments"
            if isComments {
                details.commentsToken = p["content"].first("token").string
                details.commentsCount = p["header"]["engagementPanelTitleHeaderRenderer"]["contextualInfo"].text
            }
        }
        switch root.first("likeStatus").string {
        case "LIKE": details.likeStatus = .liked
        case "DISLIKE": details.likeStatus = .disliked
        default:
            let toggles = root.first("segmentedLikeDislikeButtonRenderer")
            if toggles["likeButton"].first("isToggled").bool == true { details.likeStatus = .liked }
            else if toggles["dislikeButton"].first("isToggled").bool == true { details.likeStatus = .disliked }
        }
        details.subscribed = owner.first("subscribeButtonRenderer")["subscribed"].bool
            ?? root.first("subscribeButtonRenderer")["subscribed"].bool
        details.commentPreview = root.first("commentTeaserCarouselItemViewModel")["commentText"].string
            ?? root.first("carouselItemViewModel").first("content").string
        return details
    }

    /// Resolves `commandRuns` to URLs: external links (unwrapping YouTube's redirect), videos,
    /// timestamps in the current video (as `unreel-seek:SECONDS`) and channels.
    static func textLinks(_ runs: J, videoId: String) -> [TextLink] {
        runs.array.compactMap { run in
            guard let start = run["startIndex"].int, let length = run["length"].int else { return nil }
            let cmd = run["onTap"]["innertubeCommand"]
            var url: URL?
            if let watch = cmd["watchEndpoint"].dict.map(J.init), let id = watch["videoId"].string {
                let t = watch["startTimeSeconds"].int ?? 0
                url = id == videoId && t > 0 ? URL(string: "unreel-seek:\(t)") : URL(string: "https://youtu.be/\(id)" + (t > 0 ? "?t=\(t)" : ""))
            } else if let raw = cmd["urlEndpoint"]["url"].string ?? cmd["commandMetadata"]["webCommandMetadata"]["url"].string {
                if let comps = URLComponents(string: raw), comps.path == "/redirect",
                   let q = comps.queryItems?.first(where: { $0.name == "q" })?.value {
                    url = URL(string: q)
                } else if raw.hasPrefix("/") {
                    url = URL(string: "https://www.youtube.com" + raw)
                } else {
                    url = URL(string: raw)
                }
            } else if let id = cmd["browseEndpoint"]["browseId"].string {
                url = URL(string: "https://www.youtube.com/channel/\(id)")
            }
            return url.map { TextLink(start: start, length: length, url: $0) }
        }
    }

    // MARK: Comments

    static func comments(_ root: J) -> (comments: [Comment], continuation: String?) {
        var out: [Comment] = []
        var continuation: String?
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                for (key, value) in d {
                    let j = J(value)
                    switch key {
                    case "commentThreadRenderer":
                        if let c = comment(j.first("commentRenderer")) { out.append(c) }
                    case "commentRenderer":
                        if let c = comment(j) { out.append(c) }
                    case "continuationItemRenderer":
                        if let t = j.first("token").string { continuation = t }
                    default:
                        walk(value)
                    }
                }
            } else if let a = node as? [Any] {
                a.forEach(walk)
            }
        }
        if let v = root.value { walk(v) }
        return (out, continuation)
    }

    private static func comment(_ r: J) -> Comment? {
        guard let id = r["commentId"].string else { return nil }
        return Comment(
            id: id,
            author: r["authorText"].text ?? "",
            avatar: r["authorThumbnail"].thumbnailURL,
            text: r["contentText"].text ?? "",
            likes: r["voteCount"].text,
            published: r["publishedTimeText"].text,
            replies: r["replyCount"].int ?? 0,
            isPinned: r["pinnedCommentBadge"].exists,
            isOwner: r["authorIsChannelOwner"].bool ?? false)
    }

    // MARK: Channel

    static func channelPage(_ root: J, id: String) -> ChannelPage {
        let header = root["header"]
        let vm = header.first("pageHeaderViewModel")
        let name = header["pageHeaderRenderer"]["pageTitle"].string
            ?? vm["title"].first("content").string
            ?? header.first("title").text ?? ""
        let avatar = vm["image"].first("image").thumbnailURL ?? header.first("avatar").thumbnailURL
        let banner = vm["banner"].first("image").thumbnailURL
        let parts = vm["metadata"].all("metadataParts").flatMap { $0.array.compactMap { $0["text"]["content"].string } }
        let handle = parts.first { $0.hasPrefix("@") }
        let details = parts.filter { !$0.hasPrefix("@") }

        var tabs: [ChannelTab] = []
        for tab in root.all("tabRenderer") {
            guard let title = tab["title"].string, let params = tab["endpoint"]["browseEndpoint"]["params"].string else { continue }
            tabs.append(ChannelTab(title: title, params: params))
        }
        var page = ChannelPage(channel: ChannelItem(id: id, name: name, avatar: avatar, subtitle: details.first { $0.contains("subscriber") }),
                               handle: handle, banner: banner, details: details, tabs: tabs)
        page.subscribed = root.first("subscribeButtonRenderer")["subscribed"].bool
            ?? root.first("subscriptionStateEntity")["subscribed"].bool
        return page
    }

    // MARK: Account

    static func account(_ root: J) -> Account? {
        let h = root.first("activeAccountHeaderRenderer")
        guard let name = h["accountName"].text else { return nil }
        return Account(name: name, handle: h["channelHandle"].text, avatar: h["accountPhoto"].thumbnailURL)
    }
}
