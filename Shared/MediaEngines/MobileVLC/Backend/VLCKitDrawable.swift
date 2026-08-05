//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import UIKit
import VLCKit

// [MobileVLC4 fork]

/// The surface libVLC draws into, and the bridge that buys us Picture in Picture.
///
/// VLCKit 4 will not hand out a PiP controller for a plain `UIView`. The
/// drawable has to conform to `VLCPictureInPictureDrawable` and supply an object
/// that can drive playback while the app is backgrounded — then VLCKit builds
/// and owns the `AVPictureInPictureController` itself. That is the entire
/// contract; there is no AVKit plumbing on our side.
///
/// This wraps a view rather than subclassing one on purpose: `VLCDrawable`
/// requires a `bounds()` *method*, which would collide with `UIView.bounds`.
///
/// Deliberately **not** `@MainActor`. libVLC calls `addSubview(_:)`/`bounds()`
/// from its video-output thread and PiP calls the media controls from AVKit's,
/// so this type must be safe to touch from anywhere. It only forwards to
/// `VLCMediaPlayer`, which does its own locking, and hops to main before
/// reaching anything of ours. See VLCKitBackend for why that rule matters.
final class VLCKitDrawable: NSObject {

    /// The view handed to SwiftUI. libVLC adds its own output as a subview.
    let view: UIView

    private weak var player: VLCMediaPlayer?

    /// Supplied by VLCKit once PiP becomes available — nil until then, and the
    /// honest signal for whether to offer the button at all.
    private var pictureInPictureController: (any VLCPictureInPictureWindowControlling)?

    /// Called on the main thread when PiP starts or stops.
    var onPictureInPictureChange: ((Bool) -> Void)?

    init(player: VLCMediaPlayer) {
        self.player = player

        view = UIView()
        view.backgroundColor = .black

        // libVLC sizes its output from the drawable's bounds, so the view must
        // track its parent rather than wait on SwiftUI's layout pass.
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        super.init()
    }

    var isPictureInPictureAvailable: Bool {
        pictureInPictureController != nil
    }

    func startPictureInPicture() {
        pictureInPictureController?.startPictureInPicture()
    }

    func stopPictureInPicture() {
        pictureInPictureController?.stopPictureInPicture()
    }

    /// PiP draws its own transport controls from the values below, and they go
    /// stale unless something pushes an update. Call on every state change.
    func invalidatePlaybackState() {
        pictureInPictureController?.invalidatePlaybackState()
    }
}

// MARK: - VLCDrawable

extension VLCKitDrawable: VLCDrawable {

    func addSubview(_ view: UIView) {
        self.view.addSubview(view)
    }

    func bounds() -> CGRect {
        view.bounds
    }
}

// MARK: - VLCPictureInPictureDrawable

extension VLCKitDrawable: VLCPictureInPictureDrawable {

    func mediaController() -> any VLCPictureInPictureMediaControlling {
        self
    }

    func pictureInPictureReady() -> ((any VLCPictureInPictureWindowControlling)?) -> Void {
        { [weak self] controller in
            guard let self, let controller else { return }

            self.pictureInPictureController = controller

            controller.stateChangeEventHandler = { [weak self] isStarted in
                DispatchQueue.main.async {
                    self?.onPictureInPictureChange?(isStarted)
                }
            }
        }
    }
}

// MARK: - VLCPictureInPictureMediaControlling

/// What PiP calls to drive playback from its own floating window.
extension VLCKitDrawable: VLCPictureInPictureMediaControlling {

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        guard let player else {
            completion()
            return
        }

        _ = player.jump(withOffset: Int32(clamping: offset), completion: completion)
    }

    func mediaLength() -> Int64 {
        Int64(player?.media?.length.intValue ?? 0)
    }

    func mediaTime() -> Int64 {
        Int64(player?.time.intValue ?? 0)
    }

    func isMediaSeekable() -> Bool {
        player?.isSeekable ?? false
    }

    func isMediaPlaying() -> Bool {
        player?.isPlaying ?? false
    }
}
