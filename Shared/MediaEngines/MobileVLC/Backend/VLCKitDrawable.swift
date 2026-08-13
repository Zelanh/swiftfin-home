//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging
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
/// The type is deliberately **not** `@MainActor` as a whole, because it can't
/// be: libVLC calls `addSubview(_:)`/`bounds()` from its video-output thread and
/// PiP calls the media controls from AVKit's. Instead the split is explicit:
///
///   - **Reachable from any thread** — the `VLCDrawable` and
///     `VLCPictureInPictureMediaControlling` conformances. They touch only
///     `view` (a `let`) and `player` (a weak reference, assigned once in `init`,
///     and Swift's weak reads are atomic). Everything they call on
///     `VLCMediaPlayer` is VLCKit's business to lock, not ours.
///   - **Main-actor confined** — every piece of mutable state this type owns,
///     marked individually below. VLCKit hands those values over from its own
///     thread, so the hop happens before they are touched.
///
/// See VLCKitBackend for the same rule applied to its delegate callbacks, and
/// for what happens when it is broken.
final class VLCKitDrawable: NSObject {

    /// The view handed to SwiftUI. libVLC adds its own output as a subview.
    let view: UIView

    private weak var player: VLCMediaPlayer?

    /// Supplied by VLCKit once PiP becomes available — nil until then, and the
    /// honest signal for whether to offer the button at all.
    ///
    /// Main-actor confined, and that is load-bearing. VLCKit hands the controller
    /// over from its own thread while every reader below runs on the main actor,
    /// so before this annotation the same variable was written on one thread and
    /// read on another with nothing in between. That is a data race whether or
    /// not it ever misbehaved — and the kind that surfaces on a slower device, or
    /// never, which is worse.
    @MainActor
    private var pictureInPictureController: (any VLCPictureInPictureWindowControlling)?

    /// Called on the main thread when PiP starts or stops.
    @MainActor
    var onPictureInPictureChange: ((Bool) -> Void)?

    /// Called on the main thread once VLCKit hands over a PiP controller.
    ///
    /// This has to be an event rather than something the UI polls: VLCKit
    /// offers the controller only after video output is up, which is *after*
    /// the last playback-state change. Anything that samples availability on a
    /// state change samples it too early, every time, and the button never
    /// appears.
    @MainActor
    var onPictureInPictureAvailable: (() -> Void)?

    init(player: VLCMediaPlayer) {
        self.player = player

        view = UIView()
        view.backgroundColor = .black

        // libVLC sizes its output from the drawable's bounds, so the view must
        // track its parent rather than wait on SwiftUI's layout pass.
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        super.init()

        A2LeakProbe.born("VLCKitDrawable", self)
    }

    deinit {
        A2LeakProbe.died("VLCKitDrawable", self)
    }

    // The four below are the readers the confinement above exists for. All are
    // called from `VLCKitBackend`, which is already `@MainActor`, so nothing at
    // the call sites changes — the annotation just makes the rule enforceable
    // instead of remembered.

    @MainActor
    var isPictureInPictureAvailable: Bool {
        pictureInPictureController != nil
    }

    @MainActor
    func startPictureInPicture() {
        pictureInPictureController?.startPictureInPicture()
    }

    @MainActor
    func stopPictureInPicture() {
        pictureInPictureController?.stopPictureInPicture()
    }

    /// PiP draws its own transport controls from the values below, and they go
    /// stale unless something pushes an update. Call on every state change.
    @MainActor
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

            // VLCKit calls this from its own thread. Everything we keep lives on
            // the main actor, so the hop comes first and the assignment happens
            // inside it — that assignment sitting out here, on VLCKit's thread,
            // was the data race.
            //
            // `Task { @MainActor }` rather than `DispatchQueue.main.async`
            // because the concurrency checker understands the first and not the
            // second: with a dispatch block the annotations above would buy
            // documentation but no enforcement.
            Task { @MainActor in
                self.pictureInPictureController = controller

                controller.stateChangeEventHandler = { [weak self] isStarted in
                    Task { @MainActor in
                        self?.onPictureInPictureChange?(isStarted)
                    }
                }

                self.onPictureInPictureAvailable?()
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

// MARK: - A2 leak probe

// [A2 diagnostic] TEMPORARY — delete this block and its six call sites once the
// question is answered. See Analisis20260807.md, finding A2.
//
// The engine layer has no `deinit` anywhere, which is exactly why a suspected
// retain cycle through Picture in Picture has stayed a suspicion. `mediaController()`
// hands `self` to VLCKit, and this type holds the controller VLCKit hands back;
// if VLCKit keeps the media controller strongly, that is a cycle and neither
// object ever dies.
//
// Recording birth and death of the three long-lived objects turns the question
// into something countable: play three videos, then read the log. Three births
// and three deaths per type means no leak. Fewer deaths than births names the
// leaking type precisely, which reasoning about the ownership graph cannot.
//
// `.notice` because nothing else in the app logs at that level — filtering the
// in-app console by it shows this and nothing else.
enum A2LeakProbe {

    static func born(_ type: String, _ object: AnyObject) {
        Logger.swiftfin().notice("A2 · BORN \(type) #\(tag(object))")
    }

    static func died(_ type: String, _ object: AnyObject) {
        Logger.swiftfin().notice("A2 · DIED \(type) #\(tag(object))")
    }

    /// Last six hex digits of the address: enough to pair a death with its
    /// birth, short enough to read on a phone.
    private static func tag(_ object: AnyObject) -> String {
        String(String(UInt(bitPattern: ObjectIdentifier(object)), radix: 16).suffix(6))
    }
}
