<div align="center">

<img src="Unreel/Assets.xcassets/AppIcon.appiconset/icon.png" width="120" alt="Unreel icon">

# Unreel

**YouTube without ads, without Shorts, without sponsor reads — as a native iOS 26 app.**

![iOS 26.1+](https://img.shields.io/badge/iOS-26.1%2B-blue) ![Swift 5](https://img.shields.io/badge/Swift-5-orange) ![Sideload](https://img.shields.io/badge/distribution-sideload-lightgrey)

</div>

Unreel is a native SwiftUI YouTube client for iOS 26: Liquid Glass tab bar, native search with
suggestions, native feeds, channels, playlists, comments and a native player UI with a mini player.
YouTube's data comes from its internal API (InnerTube); playback uses YouTube's own web player in a
hidden-chrome web view, so streams keep working, while every control on screen is native. It is
meant to be sideloaded (for example with [AirRefresh](https://github.com/nikolaus018/airRefresh)).

## Features

- **No ads.** The native UI never renders ads, and the player's data is stripped of `adPlacements`,
  `playerAds` and `adSlots` before YouTube's player reads it. Filter lists from uBlock Origin
  (filters, quick fixes, privacy, unbreak), EasyList and EasyPrivacy are compiled into WebKit content
  blockers (≈108k rules) and uBlock *scriptlets* run in the player page. Lists update automatically;
  a snapshot ships with the app. If an ad still starts, it is muted and skipped.
- **No Shorts** anywhere — feeds, search, channels. Shorts links still open in the regular player.
- **SponsorBlock** skips sponsors, self-promotion and reminders, with an Undo notice.
- **Native player**: glass controls, scrubber with buffer, double-tap to seek, speed, quality,
  captions, landscape full screen, mini player above the tab bar with a zoom transition, autoplay of
  the next video, background audio, lock screen controls, Picture in Picture.
- **Native screens**: Home, Subscriptions, You (history, Watch Later, liked videos, playlists,
  channels), Search, channel pages (videos, live, playlists), playlists, comments.
- **Google sign-in** in a web sheet; the cookies are shared by the API client and the player.
- `unreel://` and youtube.com / youtu.be links open in the app.

## Build

```sh
brew install xcodegen      # only needed if you change project.yml
xcodegen generate
open Unreel.xcodeproj
```

Pick your team under *Signing & Capabilities* (the project defaults to the author's team) and run on
a device. There are no app extensions, so a free Apple ID works.

Refresh the bundled filter snapshot with `Scripts/update-bundled-filters.sh`.

## Links

- `unreel://watch?v=VIDEO_ID`
- `unreel://open?url=https://youtu.be/VIDEO_ID`

## How it is put together

| Area | Files |
| --- | --- |
| InnerTube client, models, parser, feeds | `Unreel/Data/` |
| Player (YouTube web player, native controls bridge, Now Playing, SponsorBlock) | `Unreel/Player/` |
| Filter parsing (uBO/ABP syntax → WebKit rules + page rules) | `Unreel/Blocking/FilterParser.swift` |
| Downloading, caching, compiling | `Unreel/Blocking/FilterListManager.swift`, `ContentBlockerCompiler.swift` |
| In-page engine (ad cleaning, scriptlets, player-only mode) | `Unreel/Resources/JS/engine.js` |
| SwiftUI screens and settings | `Unreel/UI/`, `Unreel/Settings/` |

Run the tests (`xcodebuild test -scheme Unreel -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`):
they parse the bundled filter lists and compile them with WebKit, and parse captured InnerTube responses.

## Credits

Filter lists by the uBlock Origin and EasyList authors (GPLv3 / CC BY-SA), SponsorBlock data by
its contributors (CC BY-NC-SA 4.0). Unreel is not affiliated with YouTube or Google.
