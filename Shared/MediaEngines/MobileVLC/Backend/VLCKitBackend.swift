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

/// The one place in Swiftfin that knows VLCKit exists.
///
/// Everything VLCKit-shaped is confined here and translated into
/// ``MediaEngineSession``. If VLCKit's API moves again — and on a 4.0 alpha it
/// will — this file absorbs it and nothing above changes.
@MainActor
final class VLCKitBackend: NSObject, MediaEngineSession {

    // MARK: Observation

    var onStateChange: ((MediaEngineState) -> Void)?
    var onTimeChange: ((MediaEnginePlaybackInfo) -> Void)?

    // MARK: State

    private let player: VLCMediaPlayer

    /// Whether the stop we are about to observe is one we asked for.
    ///
    /// This is the whole `.ended` discriminator. libVLC 4 reports reaching the
    /// end of a media and being stopped by the user as the same `Stopping`
    /// state, so intent — not playback position — is what separates them.
    private var didRequestStop = false

    /// `Stopping` and `Stopped` both arrive for a single ending. Only the first
    /// becomes a terminal event, or the app would try to advance twice.
    private var didEmitTerminalState = false

    /// Track selection and resume position can only be applied once the engine
    /// has actually opened the media and published its track list.
    private var pendingConfiguration: MediaEngineConfiguration?

    // MARK: Lifecycle

    /// - Parameter subtitleStyle: applied as engine-creation options, because
    ///   VLCKit 4 no longer exposes subtitle font or colour as live properties.
    ///   Only ``setSubtitleStyle(_:)``'s scale can change afterwards.
    init(subtitleStyle: MediaEngineSubtitleStyle? = nil) {
        player = VLCMediaPlayer(options: Self.engineOptions(for: subtitleStyle))
        super.init()
        player.delegate = self
    }

    private static func engineOptions(for style: MediaEngineSubtitleStyle?) -> [String] {
        guard let style else { return [] }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        _ = style.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let packed = (Int(red * 255) << 16) | (Int(green * 255) << 8) | Int(blue * 255)

        // libVLC ignores options it does not recognise, so a renamed option
        // degrades to the default styling rather than failing to start.
        return [
            "--freetype-font=\(style.fontName)",
            "--freetype-color=\(packed)",
        ]
    }

    // MARK: Video surface and Picture in Picture

    /// The drawable is created up front and kept for the engine's lifetime:
    /// VLCKit only offers a PiP controller for a drawable that declares itself
    /// PiP-capable, and it does so asynchronously once output is running.
    private lazy var drawable: VLCKitDrawable = {
        let drawable = VLCKitDrawable(player: player)
        player.drawable = drawable
        return drawable
    }()

    /// The view to place behind Swiftfin's own controls.
    var videoView: UIView {
        drawable.view
    }

    /// Whether VLCKit has handed us a PiP controller yet. False on a device or
    /// a media that cannot do it, so the button can hide rather than lie.
    var isPictureInPictureAvailable: Bool {
        drawable.isPictureInPictureAvailable
    }

    func startPictureInPicture() {
        drawable.startPictureInPicture()
    }

    /// Notified on the main thread when PiP starts or stops.
    var onPictureInPictureChange: ((Bool) -> Void)? {
        get { drawable.onPictureInPictureChange }
        set { drawable.onPictureInPictureChange = newValue }
    }

    /// Notified on the main thread once PiP becomes available.
    var onPictureInPictureAvailable: (() -> Void)? {
        get { drawable.onPictureInPictureAvailable }
        set { drawable.onPictureInPictureAvailable = newValue }
    }

    // MARK: MediaEngineSession

    func load(_ configuration: MediaEngineConfiguration) {
        didRequestStop = false
        didEmitTerminalState = false
        pendingConfiguration = configuration

        guard let media = VLCMedia(url: configuration.url) else {
            onStateChange?(.error)
            return
        }

        for sidecar in configuration.sidecars {
            let slave = VLCMediaSlave(
                url: sidecar.url,
                type: sidecar.kind == .subtitle ? .subtitle : .audio,
                priority: sidecar.isEnforced ? 4 : 0
            )
            // Returns whether the engine accepted it; a rejected sidecar just
            // means that subtitle is unavailable, not that playback should fail.
            _ = media.addSlave(slave)
        }

        player.media = media
        player.rate = configuration.rate

        if configuration.autoPlay {
            player.play()
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        didRequestStop = true
        player.stop()
    }

    func setSeconds(_ seconds: Duration) {
        player.time = VLCTime(int: Int32(clamping: seconds.microseconds / 1000))
    }

    func setRate(_ rate: Float) {
        player.rate = rate
    }

    func selectAudioTrack(at index: Int) {
        let tracks = player.audioTracks
        guard tracks.indices.contains(index) else { return }
        // Swift names an ObjC boolean property after its custom getter, so the
        // settable spelling is `isSelectedExclusively`, not the declared name.
        tracks[index].isSelectedExclusively = true
    }

    func selectSubtitleTrack(at index: Int?) {
        guard let index else {
            player.deselectAllTextTracks()
            return
        }

        let tracks = player.textTracks
        guard tracks.indices.contains(index) else { return }
        // Swift names an ObjC boolean property after its custom getter, so the
        // settable spelling is `isSelectedExclusively`, not the declared name.
        tracks[index].isSelectedExclusively = true
    }

    func setAudioOffset(_ offset: Duration) {
        player.currentAudioPlaybackDelay = Int(offset.microseconds)
    }

    func setSubtitleOffset(_ offset: Duration) {
        player.currentVideoSubTitleDelay = Int(offset.microseconds)
    }

    func setSubtitleStyle(_ style: MediaEngineSubtitleStyle) {
        // Only the scale is live in VLCKit 4; font and colour were fixed when
        // this backend was created. See MediaEngineSubtitleStyle.
        player.currentSubTitleFontScale = Float(style.size)
    }

    func setAspectFill(_ isAspectFill: Bool) {
        // libVLC 4 replaced libVLC 3's crop-geometry strings with a fit mode.
        player.videoFitMode = isAspectFill ? .larger : .smaller
    }

    // MARK: Snapshot

    private func currentPlaybackInfo() -> MediaEnginePlaybackInfo {
        let statistics = player.media?.statistics

        return MediaEnginePlaybackInfo(
            seconds: .milliseconds(Int(player.time.intValue)),
            videoSize: player.videoSize,
            droppedFrames: Int(statistics?.lostPictures ?? 0),
            corruptedFrames: Int(statistics?.demuxCorrupted ?? 0),
            audioTracks: Self.mapped(player.audioTracks),
            subtitleTracks: Self.mapped(player.textTracks)
        )
    }

    // VLCKit 4 renames `VLCMediaPlayerTrack` to a nested `VLCMediaPlayer.Track`
    // via NS_SWIFT_NAME, so the flat ObjC spelling does not exist in Swift.
    private static func mapped(_ tracks: [VLCMediaPlayer.Track]) -> [MediaEngineTrack] {
        tracks.enumerated().map { index, track in
            MediaEngineTrack(
                index: index,
                id: track.trackId,
                title: track.trackName,
                isSelected: track.isSelected
            )
        }
    }

    /// Apply the parts of a configuration that need a live, opened media.
    ///
    /// Track lists do not exist until the engine has parsed the stream, and a
    /// resume seek before that is discarded, so both wait for the first
    /// `playing`.
    private func applyPendingConfiguration() {
        guard let configuration = pendingConfiguration else { return }
        pendingConfiguration = nil

        if let audioTrackIndex = configuration.audioTrackIndex {
            selectAudioTrack(at: audioTrackIndex)
        }

        selectSubtitleTrack(at: configuration.subtitleTrackIndex)

        if configuration.startSeconds > .zero {
            setSeconds(configuration.startSeconds)
        }
    }
}

// MARK: - VLCMediaPlayerDelegate

/// libVLC 4 delivers these callbacks on its own threads, and often from *inside*
/// the player's event dispatch while `vlc_player_Lock` is already held. That lock
/// is not recursive: reading any `VLCMediaPlayer` property from here re-enters it
/// and aborts the process — which is exactly what pausing used to do, by way of
/// `decoder_on_output_paused` → time discontinuity → `videoSize`.
///
/// So every callback does nothing but hop to the main actor. By the time the hop
/// runs, the event has returned and the lock is free. It also puts the
/// `@Published` updates on the thread SwiftUI requires, which is the other half
/// of why the overlay looked frozen.
extension VLCKitBackend: VLCMediaPlayerDelegate {

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.handle(newState)
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // `aNotification` is deliberately not captured: it is not Sendable, and
        // the snapshot is read fresh on the main actor anyway.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onTimeChange?(self.currentPlaybackInfo())
        }
    }

    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak self] in
            self?.handleBuffering(progress)
        }
    }

    // MARK: Main-actor handlers

    private func handle(_ newState: VLCMediaPlayerState) {
        switch newState {
        case .opening:
            onStateChange?(.opening)
        case .playing:
            applyPendingConfiguration()
            onStateChange?(.playing)
            // PiP renders its own transport controls from our media-controlling
            // answers; without this nudge they keep showing the previous state.
            drawable.invalidatePlaybackState()
        case .paused:
            onStateChange?(.paused)
            drawable.invalidatePlaybackState()
        case .error:
            didEmitTerminalState = true
            onStateChange?(.error)
        case .stopping,
             .stopped:
            // Both arrive for one ending; report the first and ignore the rest.
            guard !didEmitTerminalState else { return }
            didEmitTerminalState = true
            onStateChange?(didRequestStop ? .stopped : .ended)
        case .nothingSpecial:
            break
        @unknown default:
            break
        }
    }

    private func handleBuffering(_ progress: Float) {
        // libVLC 4 dropped the buffering *state*; this callback is what is left,
        // and on a network stream it fires repeatedly. Reporting `.buffering`
        // without ever taking it back left the overlay showing a spinner for the
        // rest of playback — the reason the online player's controls were dead
        // while the offline one, which never rebuffers, behaved.
        guard !didEmitTerminalState else { return }

        if progress < 1.0 {
            onStateChange?(.buffering)
        } else if player.isPlaying {
            onStateChange?(.playing)
        }
    }
}
