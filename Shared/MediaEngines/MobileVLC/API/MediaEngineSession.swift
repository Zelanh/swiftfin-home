//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

// [MobileVLC4 fork]

/// The fork's playback contract. One VLC engine sits behind it.
///
/// The rule this exists to enforce:
///
/// > Outside `Swiftfin/MediaEngines/MobileVLC/`, nothing imports `VLCKit` and
/// > no VLCKit type appears in a signature.
///
/// Everything above this line — `MediaPlayerManager`, the player views, the
/// offline player — talks in the fork's own vocabulary. Swapping engines, or
/// riding out the API churn of a VLCKit alpha, then means editing one folder
/// instead of auditing the app.
///
/// Kept deliberately small: it covers only what Swiftfin actually calls today.
/// Resist widening it to mirror libVLC; an engine facade that exposes
/// everything is just libVLC with extra steps.
@MainActor
protocol MediaEngineSession: AnyObject {

    // MARK: Observation

    /// Playback state transitions, including the synthesised
    /// ``MediaEngineState/ended`` that drives "play next episode".
    var onStateChange: ((MediaEngineState) -> Void)? { get set }

    /// Time updates, carrying the current snapshot of playback information.
    var onTimeChange: ((MediaEnginePlaybackInfo) -> Void)? { get set }

    // MARK: Lifecycle

    /// Replace the current media with a new one and apply its configuration.
    func load(_ configuration: MediaEngineConfiguration)

    func play()

    func pause()

    /// Stop playback at our request.
    ///
    /// Implementations must remember that this stop was deliberate, so the
    /// engine's stop notification is reported as ``MediaEngineState/stopped``
    /// and not mistaken for ``MediaEngineState/ended``.
    func stop()

    // MARK: Position

    func setSeconds(_ seconds: Duration)

    func setRate(_ rate: Float)

    // MARK: Tracks

    /// Select the audio track at this position in ``MediaEnginePlaybackInfo/audioTracks``.
    func selectAudioTrack(at index: Int)

    /// Select the subtitle track at this position in
    /// ``MediaEnginePlaybackInfo/subtitleTracks``, or pass `nil` to turn
    /// subtitles off.
    func selectSubtitleTrack(at index: Int?)

    // MARK: Presentation

    /// Shift audio relative to video; negative values play audio earlier.
    func setAudioOffset(_ offset: Duration)

    /// Shift subtitles relative to video; negative values show them earlier.
    func setSubtitleOffset(_ offset: Duration)

    /// Apply the live part of a subtitle style. See
    /// ``MediaEngineSubtitleStyle`` for what cannot change mid-item.
    func setSubtitleStyle(_ style: MediaEngineSubtitleStyle)

    /// Crop to fill the surface instead of fitting inside it.
    func setAspectFill(_ isAspectFill: Bool)
}
