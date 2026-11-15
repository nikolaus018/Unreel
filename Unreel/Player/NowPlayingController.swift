import MediaPlayer
import UIKit

/// Lock screen / Control Center info and remote commands for the video playing in the web view.
@MainActor
final class NowPlayingController {
    struct State: Equatable {
        var videoId: String?
        var title: String
        var author: String
        var duration: Double
        var time: Double
        var rate: Double
        var playing: Bool
    }

    var onCommand: ((Command) -> Void)?
    enum Command { case play, pause, toggle, seekBy(Double), seekTo(Double), next, previous }

    private var configured = false
    private var artworkFor: String?
    private var artwork: MPMediaItemArtwork?
    private var enabled = true

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { clear() }
    }

    func update(_ state: State) {
        guard enabled, state.videoId != nil else { return }
        configureCommands()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: state.author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.time,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? state.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if state.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = state.duration }
        if let artwork, artworkFor == state.videoId { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.playing ? .playing : .paused
        if let id = state.videoId, artworkFor != id { loadArtwork(id) }
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadArtwork(_ id: String) {
        artworkFor = id
        artwork = nil
        Task {
            for quality in ["maxresdefault", "hqdefault"] {
                guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(quality).jpg"),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data) else { continue }
                guard self.artworkFor == id else { return }
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artwork = art
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                return
            }
        }
    }

    private func configureCommands() {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.onCommand?(.play); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.onCommand?(.pause); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onCommand?(.toggle); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.onCommand?(.seekBy(10)); return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.onCommand?(.seekBy(-10)); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.onCommand?(.next); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.onCommand?(.previous); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onCommand?(.seekTo(e.positionTime))
            return .success
        }
    }
}
