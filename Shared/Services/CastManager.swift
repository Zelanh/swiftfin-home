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
import UIKit

extension Container {

    var castManager: Factory<CastManager> {
        self { CastManager() }.singleton
    }
}

// MARK: - CastManager

final class CastManager: NSObject, ObservableObject {

    static let jellyfinReceiverAppID = "F007D354"

    /// The Jellyfin Cast receiver listens for commands on this custom Cast namespace
    /// — the exact same one the official `jellyfin-web` Chromecast sender uses.
    /// Standard CAF `loadMedia` requests are NOT handled by the Jellyfin receiver;
    /// it expects a JSON payload (`{command, serverAddress, accessToken, options}`)
    /// delivered via this channel.
    private static let jellyfinNamespace = "urn:x-cast:com.connectsdk"

    @Published private(set) var isSessionActive = false
    @Published private(set) var connectedDeviceName: String? = nil
    @Published private(set) var hasAvailableDevices = false
    @Published private(set) var castPlayerState: GCKMediaPlayerState = .idle
    @Published private(set) var currentCastPosition: TimeInterval = 0

    /// Position at the moment a Cast session ended, used to resume local playback.
    private(set) var castEndedPosition: Duration? = nil

    /// Channel bound to the Jellyfin custom namespace for the active session.
    /// Recreated each time a session starts/resumes; cleared when it ends.
    private var jellyfinChannel: GCKGenericChannel?

    override init() {
        super.init()
        GCKCastContext.sharedInstance().sessionManager.add(self)
        GCKCastContext.sharedInstance().discoveryManager.add(self)
    }

    // MARK: - Media Loading

    /// Send a `PlayNow` command to the Jellyfin receiver via its custom namespace.
    ///
    /// The receiver uses this message to construct its own playback URL on the
    /// Jellyfin server (from `serverAddress` + `accessToken` + item `Id`), so we
    /// don't need to send a stream URL ourselves.
    ///
    /// @MainActor because we read main-actor-isolated properties on `MediaPlayerItem`
    /// (`selectedAudioStreamIndex`, `selectedSubtitleStreamIndex`).
    @MainActor
    func load(item: MediaPlayerItem) {
        guard let userSession = Container.shared.currentUserSession() else { return }
        guard let channel = jellyfinChannel else { return }

        // Jellyfin uses ticks (100ns units): 1 second = 10,000,000 ticks.
        let startSeconds = item.baseItem.startSeconds?.seconds ?? 0
        let resumeOffset = Double(Defaults[.VideoPlayer.resumeOffset])
        let adjustedSeconds = max(0, startSeconds - resumeOffset)
        let startPositionTicks = Int64(adjustedSeconds * 10_000_000)

        // Re-encode the BaseItemDto back to its server JSON shape. JellyfinAPI's
        // CodingKeys map Swift camelCase ↔ server PascalCase, so a round-trip
        // through JSONEncoder + JSONSerialization gives us a [String: Any] in
        // the exact format the receiver expects in `options.items[]`.
        guard let baseItemJSON = try? Self.encodeToDictionary(item.baseItem) else { return }

        let options: [String: Any] = [
            "items": [baseItemJSON],
            "startPositionTicks": startPositionTicks,
            "mediaSourceId": item.mediaSource.id ?? "",
            "audioStreamIndex": item.selectedAudioStreamIndex ?? -1,
            "subtitleStreamIndex": item.selectedSubtitleStreamIndex ?? -1,
        ]

        let message = baseMessage(
            command: "PlayNow",
            userSession: userSession,
            options: options
        )

        // Listen for media status updates so the iOS UI (position, play/pause state)
        // stays in sync with whatever the receiver decides to play.
        currentSession?.remoteMediaClient?.add(self)

        sendCustomMessage(message, on: channel)
    }

    /// Send the `Identify` handshake to the receiver immediately after the
    /// session is established. The jellyfin-web client does this on connect —
    /// without it the receiver may ignore subsequent `PlayNow` commands.
    private func sendIdentify() {
        guard let channel = jellyfinChannel else { return }
        guard let userSession = Container.shared.currentUserSession() else { return }

        let message = baseMessage(
            command: "Identify",
            userSession: userSession,
            options: [:]
        )
        sendCustomMessage(message, on: channel)
    }

    /// Build the top-level JSON payload shape that the Jellyfin receiver expects
    /// for every command on the custom namespace. Matches `jellyfin-web`'s
    /// `sendMessage` shape: command + identity + session + nested options.
    private func baseMessage(
        command: String,
        userSession: UserSession,
        options: [String: Any]
    ) -> [String: Any] {
        var message: [String: Any] = [
            "command": command,
            "serverAddress": userSession.server.currentURL.absoluteString,
            "accessToken": userSession.user.accessToken,
            "userId": userSession.user.id,
            "deviceId": "\(UIDevice.platform)_\(UIDevice.vendorUUIDString)",
            "serverId": userSession.server.id,
            "options": options,
        ]
        // Server version is opportunistic — only included if we have it cached.
        if let version = StoredValues[.Server.publicInfo(id: userSession.server.id)].version {
            message["serverVersion"] = version
        }
        if let receiverName = currentSession?.device.friendlyName {
            message["receiverName"] = receiverName
        }
        return message
    }

    // MARK: - Playback Control
    //
    // Standard CAF media commands. The Jellyfin receiver runs CAF underneath,
    // so play/pause/seek delivered through GCKRemoteMediaClient act on the
    // active media session and also keep our `mediaStatus` observation working.

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
        currentSession?.remoteMediaClient?.setPlaybackRate(rate, customData: nil)
    }

    func endSession() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    // MARK: - Private Helpers

    private var currentSession: GCKCastSession? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession
    }

    private func sendCustomMessage(_ message: [String: Any], on channel: GCKGenericChannel) {
        guard
            let jsonData = try? JSONSerialization.data(withJSONObject: message),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        try? channel.sendTextMessage(jsonString)
    }

    private static func encodeToDictionary<T: Encodable>(_ value: T) throws -> [String: Any]? {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Attach a fresh custom-namespace channel to the given session.
    /// Called from session-start AND session-resume callbacks.
    private func attachJellyfinChannel(to session: GCKCastSession) {
        let channel = GCKGenericChannel(namespace: Self.jellyfinNamespace)
        session.add(channel)
        jellyfinChannel = channel
    }
}

// MARK: - GCKSessionManagerListener

extension CastManager: GCKSessionManagerListener {

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        attachJellyfinChannel(to: session)
        DispatchQueue.main.async {
            self.isSessionActive = true
            self.connectedDeviceName = session.device.friendlyName
            self.castEndedPosition = nil
            session.remoteMediaClient?.add(self)
            // Send the Identify handshake the receiver expects before any other command.
            self.sendIdentify()
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        jellyfinChannel = nil
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
        attachJellyfinChannel(to: session)
        DispatchQueue.main.async {
            self.isSessionActive = true
            self.connectedDeviceName = session.device.friendlyName
            session.remoteMediaClient?.add(self)
            // Re-identify on resume too — the receiver may have lost state.
            self.sendIdentify()
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
