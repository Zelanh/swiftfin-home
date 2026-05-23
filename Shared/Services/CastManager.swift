//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import Foundation
import GoogleCast
import JellyfinAPI

extension Container {

    var castManager: Factory<CastManager> {
        self { CastManager() }.singleton
    }
}

// MARK: - CastManager

final class CastManager: NSObject, ObservableObject {

    static let jellyfinReceiverAppID = "F007D354"

    @Published private(set) var isSessionActive = false
    @Published private(set) var connectedDeviceName: String? = nil
    @Published private(set) var hasAvailableDevices = false
    @Published private(set) var castPlayerState: GCKMediaPlayerState = .idle
    @Published private(set) var currentCastPosition: TimeInterval = 0

    /// Position at the moment a Cast session ended, used to resume local playback.
    private(set) var castEndedPosition: Duration? = nil

    override init() {
        super.init()
        GCKCastContext.sharedInstance().sessionManager.add(self)
        GCKCastContext.sharedInstance().discoveryManager.add(self)
    }

    // MARK: - Media Loading

    func load(item: MediaPlayerItem) {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        guard let userSession = Container.shared.currentUserSession() else { return }

        let mediaInfo = buildMediaInformation(for: item, userSession: userSession)

        let requestData = GCKMediaLoadRequestData()
        requestData.mediaInformation = mediaInfo
        let resumeOffset = Double(Defaults[.VideoPlayer.resumeOffset])
        requestData.startTime = max(0, (item.baseItem.startSeconds?.seconds ?? 0) - resumeOffset)
        requestData.autoplay = true

        session.remoteMediaClient?.loadMedia(with: requestData)
        session.remoteMediaClient?.add(self)
    }

    // MARK: - Playback Control

    func play() {
        currentSession?.remoteMediaClient?.play()
    }

    func pause() {
        currentSession?.remoteMediaClient?.pause()
    }

    func seekTo(_ position: TimeInterval) {
        let options = GCKMediaSeekOptions()
        options.interval = position
        options.resumeState = .unchanged
        currentSession?.remoteMediaClient?.seek(with: options)
    }

    func seek(by delta: TimeInterval) {
        let current = currentSession?.remoteMediaClient?.mediaStatus?.streamPosition ?? currentCastPosition
        seekTo(max(0, current + delta))
    }

    func setPlaybackRate(_ rate: Float) {
        currentSession?.remoteMediaClient?.setPlaybackRate(Double(rate), customData: nil)
    }

    func endSession() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    // MARK: - Private Helpers

    private var currentSession: GCKCastSession? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession
    }

    private func buildMediaInformation(for item: MediaPlayerItem, userSession: UserSession) -> GCKMediaInformation {
        let metadata = buildMetadata(for: item, userSession: userSession)

        let customData: [String: Any] = [
            "userId": userSession.user.id,
            "accessToken": userSession.user.accessToken,
            "serverAddress": userSession.server.currentURL.absoluteString,
            "itemId": item.baseItem.id ?? "",
            "mediaSourceId": item.mediaSource.id ?? "",
            "audioStreamIndex": item.selectedAudioStreamIndex ?? -1,
            "subtitleStreamIndex": item.selectedSubtitleStreamIndex ?? -1,
        ]

        let builder = GCKMediaInformationBuilder(contentURL: item.url)
        builder.streamType = item.baseItem.isLiveStream ? .live : .buffered
        builder.contentType = "video/mp4"
        builder.metadata = metadata
        builder.streamDuration = item.baseItem.runtime?.seconds ?? 0
        builder.customData = customData

        return builder.build()
    }

    private func buildMetadata(for item: MediaPlayerItem, userSession: UserSession) -> GCKMediaMetadata {
        let baseItem = item.baseItem
        let metadataType: GCKMediaMetadataType = baseItem.type == .episode ? .tvShow : .movie
        let metadata = GCKMediaMetadata(metadataType: metadataType)

        if baseItem.type == .episode {
            metadata.setString(baseItem.seriesName ?? baseItem.displayTitle, forKey: kGCKMetadataKeySeriesTitle)
            metadata.setString(baseItem.displayTitle, forKey: kGCKMetadataKeyEpisodeTitle)
            if let season = baseItem.parentIndexNumber {
                metadata.setInteger(season, forKey: kGCKMetadataKeySeasonNumber)
            }
            if let episode = baseItem.indexNumber {
                metadata.setInteger(episode, forKey: kGCKMetadataKeyEpisodeNumber)
            }
        } else {
            metadata.setString(baseItem.displayTitle, forKey: kGCKMetadataKeyTitle)
        }

        if let itemID = baseItem.id {
            let imageURL = userSession.server.currentURL
                .appendingPathComponent("Items")
                .appendingPathComponent(itemID)
                .appendingPathComponent("Images")
                .appendingPathComponent("Primary")
            metadata.addImage(GCKImage(url: imageURL, width: 512, height: 512))
        }

        return metadata
    }
}

// MARK: - GCKSessionManagerListener

extension CastManager: GCKSessionManagerListener {

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        DispatchQueue.main.async {
            self.isSessionActive = true
            self.connectedDeviceName = session.device.friendlyName
            self.castEndedPosition = nil
            session.remoteMediaClient?.add(self)
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        DispatchQueue.main.async {
            self.castEndedPosition = .seconds(self.currentCastPosition)
            self.isSessionActive = false
            self.connectedDeviceName = nil
            self.castPlayerState = .idle
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
        DispatchQueue.main.async {
            self.isSessionActive = false
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        DispatchQueue.main.async {
            self.isSessionActive = true
            self.connectedDeviceName = session.device.friendlyName
            session.remoteMediaClient?.add(self)
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        DispatchQueue.main.async {
            self.isSessionActive = false
        }
    }
}

// MARK: - GCKDiscoveryManagerListener

extension CastManager: GCKDiscoveryManagerListener {

    func didUpdateDeviceList() {
        DispatchQueue.main.async {
            self.hasAvailableDevices = GCKCastContext.sharedInstance().discoveryManager.deviceCount > 0
        }
    }
}

// MARK: - GCKRemoteMediaClientListener

extension CastManager: GCKRemoteMediaClientListener {

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        DispatchQueue.main.async {
            self.castPlayerState = mediaStatus?.playerState ?? .idle
            self.currentCastPosition = mediaStatus?.streamPosition ?? self.currentCastPosition
        }
    }
}
