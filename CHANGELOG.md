# Changelog

## 1.1.0 — unreleased

A design pass against Apple's Human Interface Guidelines.

- **Settings moved into You.** The tab bar now holds only content (Home, Subscriptions, You,
  Search); Settings opens from the gear button or the Settings row in You. On iPad the tab bar
  can turn into a sidebar.
- **You** shows your blocking stats as a card, and a clearer sign-in prompt when signed out.
- **Settings** rows use title-style labels like the Settings app, sections are regrouped
  (Content, SponsorBlock, Playback, Watch Page, General, Advanced), and Clear Cache and Reset
  ask for confirmation first.
- **Search:** a system Paste button opens a copied YouTube link without a paste prompt
  (replaces "Open copied YouTube link" in Settings).
- **Video cards** are real buttons with pressed feedback; tapping a channel avatar opens the
  channel. Channel rows gained a context menu.
- **Player:** every control is at least 44 pt, the scrubber has a larger touch area, and
  hardware keyboards work (Space, ←/→, F).
- **Watch page:** a compact Autoplay toggle replaces the oversized switch, Subscribe shows a
  checkmark when subscribed, and the description and comments sheets have a close button.
- **Accessibility:**
  - VoiceOver reads each video as one element (title, channel, views, age, duration, progress)
    with Go to Channel and Watch Later actions.
  - The scrubber can be adjusted with a swipe, and controls stay visible while VoiceOver is on.
  - Toasts are announced and stay longer under VoiceOver.
  - Selected states are announced (speed, quality, captions, filters, like/dislike).
- **Dynamic Type:** titles and controls use text styles, and video rows stack vertically at
  accessibility sizes. Reduce Motion turns off the skeleton pulse and press animations.
- Success haptics confirm subscribing and saving to Watch Later.

## 1.0.1 — 2026-11-15

- The progress line under the video no longer shows in full screen.

## 1.0.0 — 2026-11-15

First release.

- Native SwiftUI client for iOS 26: Home, Subscriptions, You, Search, channels, playlists,
  comments with replies, and a Liquid Glass tab bar with a mini player.
- Playback through YouTube's own web player with native controls: chapters, SponsorBlock marks,
  double-tap seeking that adds up, hold for 2×, YouTube-style rotation and full screen, autoplay
  countdown, background audio, lock-screen controls, Picture in Picture.
- Ad blocking: player data cleaned before YouTube reads it, plus uBlock Origin / EasyList filter
  lists compiled to WebKit content blockers, with automatic updates.
- No Shorts anywhere; Shorts links open in the regular player.
- SponsorBlock with configurable categories and an Undo notice.
- Google sign-in with like/dislike, subscribe, Watch Later and playlist queues.
