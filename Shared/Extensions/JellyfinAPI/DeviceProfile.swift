//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI

extension DeviceProfile {

    /// - Parameter shouldForceRemux: whether this playback should be served as a
    ///   segmented stream even though the device could play the file directly.
    ///   The caller decides, because it takes two facts this method cannot see:
    ///   that playback starts at a saved position, and that the source codec is
    ///   one the server can copy into HLS rather than re-encode. See the note at
    ///   the end of this method, and `MediaPlayerItem.build`.
    static func build(
        for videoPlayer: VideoPlayerType,
        compatibilityMode: PlaybackCompatibility,
        maxBitrate: Int? = nil,
        maxResolution: PlaybackResolution = Defaults[.VideoPlayer.Playback.appMaximumResolution],
        shouldForceRemux: Bool = false
    ) -> DeviceProfile {

        var deviceProfile: DeviceProfile = .init()

        // MARK: - Video Player Specific Logic

        deviceProfile.codecProfiles = videoPlayer.codecProfiles

        if StoredValues[.User.forceSubtitleBurnIn] {
            deviceProfile.subtitleProfiles = SubtitleProfile.build(method: .encode) {
                SubtitleFormat.allCases
            }
        } else {
            deviceProfile.subtitleProfiles = videoPlayer.subtitleProfiles
        }

        if let resolutionCodecProfile = maxResolution.codecProfile {
            deviceProfile.codecProfiles?.append(resolutionCodecProfile)
        }

        // MARK: - DirectPlay & Transcoding Profiles

        switch compatibilityMode {
        case .auto:
            deviceProfile.directPlayProfiles = videoPlayer.directPlayProfiles
            deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles

        case .mostCompatible:
            deviceProfile.directPlayProfiles = PlaybackCompatibility.Video.compatibilityDirectPlayProfile
            deviceProfile.transcodingProfiles = PlaybackCompatibility.Video.compatibilityTranscodingProfile

        case .directPlay:
            deviceProfile.directPlayProfiles = PlaybackCompatibility.Video.forcedDirectPlayProfile

        case .custom:
            let customProfileMode = Defaults[.VideoPlayer.Playback.customDeviceProfileAction]
            let playbackDeviceProfile = StoredValues[.User.customDeviceProfiles]

            if customProfileMode == .add {
                deviceProfile.directPlayProfiles = videoPlayer.directPlayProfiles
                deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles
            } else {
                deviceProfile.directPlayProfiles = []

                // Only clear the Transcoding Profiles if one of the CustomProfiles is active as a Transcoding Profile
                if playbackDeviceProfile.contains(where: { $0.useAsTranscodingProfile == true }) {
                    deviceProfile.transcodingProfiles = []
                } else {
                    deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles
                }
            }

            for profile in playbackDeviceProfile where profile.type == .video {
                deviceProfile.directPlayProfiles?.append(profile.directPlayProfile)

                if profile.useAsTranscodingProfile {
                    deviceProfile.transcodingProfiles?.append(profile.transcodingProfile)
                }
            }
        }

        // MARK: - Assign the Bitrate if provided

        if let maxBitrate {
            deviceProfile.maxStaticBitrate = maxBitrate
            deviceProfile.maxStreamingBitrate = maxBitrate
            deviceProfile.musicStreamingTranscodingBitrate = maxBitrate
        }

        // MARK: - [MobileVLC4 fork] Resuming a remuxable source rules out direct play

        // A direct-play stream is requested with `isStatic: true` — the raw file,
        // with no position parameter and no way to express one. Reaching minute
        // ten therefore means the client walking there itself, which on a
        // multi-gigabyte file took about two minutes of black screen. This is not
        // about Matroska: `isStatic` means a raw file whatever the container is.
        //
        // Emptying the direct-play list leaves the server no choice but to serve
        // through the transcoding profile, which is HLS. That makes a position
        // *addressable* — a resume becomes "fetch segment 104" instead of "read
        // until you get there", which is exactly why the native player, whose
        // profile is narrow enough that Matroska never direct-plays, feels
        // instant. Measured on an mkv/hevc resumed at 30:49: 375 ms from the
        // player appearing to frames on screen.
        //
        // The bargain only holds when the server repackages instead of
        // re-encoding, which is the caller's job to establish — the same trick
        // on an avi/mpeg4 cost about thirty seconds, because HLS cannot carry
        // MPEG-4 Part 2 and ffmpeg had to encode before there was a first
        // segment to serve.
        //
        // Starting from zero is untouched and keeps direct play, which costs the
        // server nothing and is the majority of playbacks.
        if shouldForceRemux {
            deviceProfile.directPlayProfiles = []
        }

        return deviceProfile
    }

    // MARK: - Playback Capability Queries

    /// Whether any `DirectPlayProfile` allows media with this audio codec in the given container to be played directly.
    func canPlay(type: DlnaProfileType, audioCodec: String?, container: String?) -> Bool {
        (directPlayProfiles ?? []).contains { profile in
            profile.type == type
                && profileContains(profile: profile.audioCodec, audioCodec)
                && profileContains(profile: profile.container, container)
        }
    }

    /// Whether any `DirectPlayProfile` allows media with this video codec in the given container to be played directly.
    func canPlay(type: DlnaProfileType, videoCodec: String?, container: String?) -> Bool {
        (directPlayProfiles ?? []).contains { profile in
            profile.type == type
                && profileContains(profile: profile.videoCodec, videoCodec)
                && profileContains(profile: profile.container, container)
        }
    }

    /// Whether any `SubtitleProfile` allows this format to be delivered via the given method.
    func canPlay(subtitleFormat: String?, method: SubtitleDeliveryMethod) -> Bool {
        guard let subtitleFormat = subtitleFormat?.lowercased() else { return false }
        return (subtitleProfiles ?? []).contains { profile in
            profile.method == method
                && profile.format?.lowercased() == subtitleFormat
        }
    }

    /// Parse & check membership like this is CSV as that's the format we send to the server.
    private func profileContains(profile: String?, _ candidate: String?) -> Bool {
        guard let profile else { return true }
        guard let candidate = candidate?.lowercased() else { return false }
        return profile
            .lowercased()
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == candidate }
    }
}
