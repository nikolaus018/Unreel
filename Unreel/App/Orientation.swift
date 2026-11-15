import SwiftUI
import UIKit

/// Controls which orientations the app allows, the way the YouTube app behaves:
/// - the app is portrait-only, except while the player is open;
/// - with the player open, turning the phone enters/leaves full screen;
/// - the full-screen button forces landscape (and the exit button portrait) even if the phone is
///   held the other way, until the phone is physically turned to match.
@MainActor
final class Orientation {
    static let shared = Orientation()

    private(set) var mask: UIInterfaceOrientationMask = .portrait
    private var playerVisible = false
    /// After a forced rotation, free rotation resumes once the device physically matches.
    private var waitingFor: UIInterfaceOrientationMask?
    private var observer: NSObjectProtocol?

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Orientation.shared.deviceRotated() }
        }
        if isPad { mask = .all }
    }

    func setPlayerVisible(_ visible: Bool) {
        guard !isPad, visible != playerVisible else { return }
        playerVisible = visible
        waitingFor = nil
        if visible {
            mask = .allButUpsideDown
            apply(nil)
        } else {
            mask = .portrait
            apply(.portrait)
        }
    }

    func enterFullscreen() {
        guard !isPad else { return }
        let device = UIDevice.current.orientation
        let target: UIInterfaceOrientationMask = device == .landscapeRight ? .landscapeLeft : .landscapeRight
        mask = .landscape
        waitingFor = .landscape
        apply(target)
    }

    func exitFullscreen() {
        guard !isPad else { return }
        mask = .portrait
        waitingFor = .portrait
        apply(.portrait)
    }

    private func deviceRotated() {
        guard let waiting = waitingFor, playerVisible else { return }
        let o = UIDevice.current.orientation
        let matches = (waiting == .landscape && o.isLandscape) || (waiting == .portrait && o == .portrait)
        if matches {
            waitingFor = nil
            mask = .allButUpsideDown
            apply(nil)
        }
    }

    private func apply(_ target: UIInterfaceOrientationMask?) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            // Presented controllers (the player cover) decide orientation, so refresh the whole chain.
            for window in scene.windows {
                var vc = window.rootViewController
                while let current = vc {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = current.presentedViewController
                }
            }
            if let target {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
                    print("Orientation request failed: \(error)")
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Orientation.shared.mask }
    }
}
