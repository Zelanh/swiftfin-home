//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI

// MARK: - Chromecast DeviceProfile
//
// Part of the isolated Chromecast integration (everything cast-related lives
// under Swiftfin/Chromecast/). Pure extension on `DeviceProfile` — this file
// touches no upstream code, so it never conflicts on an upstream merge.

extension DeviceProfile {

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
