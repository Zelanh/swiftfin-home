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

    static func build(
        for videoPlayer: VideoPlayerType,
        compatibilityMode: PlaybackCompatibility,
        maxBitrate: Int? = nil
    ) -> DeviceProfile {

        var deviceProfile: DeviceProfile = .init()

        // MARK: - Video Player Specific Logic

        deviceProfile.codecProfiles = videoPlayer.codecProfiles
        deviceProfile.subtitleProfiles = videoPlayer.subtitleProfiles

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

        return deviceProfile
    }

    // MARK: - Chromecast

    /// DeviceProfile for casting to the default Google media receiver.
    ///
    /// The combination the default receiver reliably plays — verified
    /// empirically against a Chromecast Ultra (and matching what Streamyfin
    /// ships): h264 video + stereo AAC inside an HLS stream with MPEG-TS
    /// segments. Anything else is transcoded by Jellyfin into exactly that,
    /// with the requested bitrate baked into the resulting TranscodingUrl.
    /// Subtitles are burned in server-side; the default receiver has no UI
    /// for external subtitle tracks.
    static func buildChromecast(maxBitrate: Int? = nil) -> DeviceProfile {

        var deviceProfile = DeviceProfile()

        deviceProfile.directPlayProfiles = chromecastDirectPlayProfiles
        deviceProfile.transcodingProfiles = chromecastTranscodingProfiles
        deviceProfile.subtitleProfiles = chromecastSubtitleProfiles

        if let maxBitrate {
            deviceProfile.maxStaticBitrate = maxBitrate
            deviceProfile.maxStreamingBitrate = maxBitrate
            deviceProfile.musicStreamingTranscodingBitrate = maxBitrate
        }

        return deviceProfile
    }

    @ArrayBuilder<DirectPlayProfile>
    private static var chromecastDirectPlayProfiles: [DirectPlayProfile] {
        DirectPlayProfile(type: .video) {
            AudioCodec.aac
            AudioCodec.mp3
        } videoCodecs: {
            VideoCodec.h264
        } containers: {
            MediaContainer.mp4
        }
    }

    @ArrayBuilder<TranscodingProfile>
    private static var chromecastTranscodingProfiles: [TranscodingProfile] {
        TranscodingProfile(
            isBreakOnNonKeyFrames: true,
            context: .streaming,
            maxAudioChannels: "2",
            minSegments: 2,
            protocol: MediaStreamProtocol.hls,
            type: .video
        ) {
            AudioCodec.aac
            AudioCodec.mp3
        } videoCodecs: {
            VideoCodec.h264
        } containers: {
            MediaContainer.ts
        }
    }

    @ArrayBuilder<SubtitleProfile>
    private static var chromecastSubtitleProfiles: [SubtitleProfile] {
        SubtitleProfile.build(method: .encode) {
            SubtitleFormat.ass
            SubtitleFormat.dvbsub
            SubtitleFormat.dvdsub
            SubtitleFormat.pgssub
            SubtitleFormat.ssa
            SubtitleFormat.subrip
            SubtitleFormat.vtt
            SubtitleFormat.xsub
        }
    }
}
