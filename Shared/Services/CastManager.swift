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

extension Defaults.Keys {

    /// The user's preferred bitrate tier when streaming to a Cast device.
    ///
    /// Uses Swiftfin's own `PlaybackBitrate` enum so the Cast picker exposes
    /// exactly the same tiers (with the same localized labels) as the global
    /// Settings → Playback Quality picker. `.auto` triggers a network speed
    /// test on the next cast, just like the local-playback path.
    ///
    /// Acts as a per-Cast override on top of
    /// `Defaults[.VideoPlayer.Playback.appMaximumBitrate]`. When the user opens
    /// the Cast quality picker and confirms a tier, that value is what's
    /// fed into `MediaPlayerItem.build(requestedBitrate:…)` so the
    /// Transcoding URL Jellyfin generates has *our* cap baked in instead of
    /// whatever was selected globally for local playback.
    static var castBitrate: Key<PlaybackBitrate> {
        Key("castBitrate", default: .auto)
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

    /// Last error reported by a `loadMedia` request, surfaced to the UI so
    /// failures are visible on-device (we have no console access on the
    /// sideloaded build). `nil` when the last load succeeded or none ran yet.
    @Published private(set) var lastLoadError: String? = nil

    /// Strong reference to the in-flight load request. `loadMedia` returns a
    /// `GCKRequest` whose delegate is only called while the request is alive.
    private var activeLoadRequest: GCKRequest?

    func clearLoadError() {
        lastLoadError = nil
    }

    /// Position at the moment a Cast session ended, used to resume local playback.
    private(set) var castEndedPosition: Duration? = nil

    /// Channel bound to the Jellyfin custom namespace for the active session.
    /// Recreated each time a session starts/resumes; cleared when it ends.
    private var jellyfinChannel: GCKGenericChannel?

    /// Bitrate tier requested from the Cast quality picker for the next `load`.
    /// `nil` means "fall back to `Defaults[.VideoPlayer.Playback.appMaximumBitrate]`"
    /// — the global Settings tier. Set by the Cast quality picker just before casting.
    var pendingBitrate: PlaybackBitrate? = nil

    /// Optional override for the audio stream index used by the next `load`.
    /// `nil` means "use whatever is selected on the MediaPlayerItem". Set by
    /// the quality picker, so the user can pick a different audio track for
    /// Cast than the one they had selected locally.
    var pendingAudioStreamIndex: Int? = nil

    override init() {
        super.init()
        let context = GCKCastContext.sharedInstance()
        context.sessionManager.add(self)
        context.discoveryManager.add(self)
        // `GCKUICastButton` from the SDK starts discovery implicitly when it
        // appears on screen. We replaced it with a plain SwiftUI button, so
        // discovery has to be kicked off manually — otherwise `deviceCount`
        // stays at 0 forever and our button never becomes visible.
        context.discoveryManager.startDiscovery()
    }

    // MARK: - Media Loading

    /// Send a `PlayNow` command to the Jellyfin receiver via its custom namespace.
    ///
    /// Before sending, the `MediaPlayerItem` we received from the local-playback
    /// flow is **rebuilt** with our Cast picker's bitrate tier (and the user's
    /// global compatibility-mode setting). That second `getPostedPlaybackInfo`
    /// call returns a fresh `MediaSource` whose `TranscodingUrl` has *our* cap
    /// baked in by Jellyfin itself, plus a fresh `playSessionID`. We inject the
    /// new `MediaSource` into the `BaseItemDto` we send so the receiver, when it
    /// inspects `items[0].MediaSources[*]`, finds the URL we want it to use
    /// instead of the one Jellyfin generated for local playback with the
    /// global `appMaximumBitrate`.
    ///
    /// This solves three things at once:
    /// 1. The Cast quality picker actually changes the resulting bitrate (it
    ///    was previously masked by `appMaximumBitrate`, which is what Jellyfin
    ///    sees when the item is built for local playback).
    /// 2. The user's compatibility-mode and custom-device-profile settings
    ///    from Settings → Playback Quality propagate to Cast.
    /// 3. The "server reuses a previous transcode session" issue we hit in
    ///    earlier iterations is dissolved organically: every cast attempt
    ///    triggers a new `getPostedPlaybackInfo`, which yields a new
    ///    `playSessionID` and a new transcoder process server-side.
    ///
    /// @MainActor because we read main-actor-isolated properties on `MediaPlayerItem`.
    @MainActor
    func load(item: MediaPlayerItem) {
        Task { await self.performLoad(item: item) }
    }

    /// Async core of `load(item:)`. Kept private so the public surface stays
    /// callable from synchronous SwiftUI contexts (`.onChange` etc.).
    ///
    /// Mirrors the native local-play model instead of the receiver's custom
    /// PlayNow protocol: we rebuild the `MediaPlayerItem` exactly like
    /// Swiftfin does when the user taps Play locally (same
    /// `getPostedPlaybackInfo` negotiation, same `TranscodingUrl`-or-direct
    /// stream URL), then hand that URL to the Chromecast via the standard
    /// CAF `loadMedia`. The receiver can't reinterpret or override a direct
    /// URL the way it did with the PlayNow JSON — it just plays it, so the
    /// picker tier (or the global Settings tier) is finally authoritative.
    @MainActor
    private func performLoad(item: MediaPlayerItem) async {
        guard let remoteMediaClient = currentSession?.remoteMediaClient else { return }

        // Rebuild the MediaPlayerItem so Jellyfin produces a stream URL
        // that respects the Cast picker tier (or, if the picker is `nil`,
        // the global `appMaximumBitrate`) AND the user's global compatibility
        // mode — the exact same call path local playback uses. If the rebuild
        // fails (offline, server hiccup, etc.) we fall back to the original
        // item so casting still works degraded rather than not at all.
        let castItem: MediaPlayerItem = await rebuildItemForCast(from: item) ?? item

        let startSeconds = castItem.baseItem.startSeconds?.seconds ?? 0
        let resumeOffset = Double(Defaults[.VideoPlayer.resumeOffset])
        let adjustedSeconds = max(0, startSeconds - resumeOffset)

        let builder = GCKMediaInformationBuilder(contentURL: castItem.url)
        builder.contentID = castItem.baseItem.id ?? castItem.url.absoluteString
        builder.streamType = .buffered
        // Transcodes are HLS playlists; direct streams are served as their
        // container (mp4 covers the overwhelming majority — the Chromecast
        // sniffs the actual container from the stream anyway).
        builder.contentType = castItem.mediaSource.transcodingURL != nil
            ? "application/x-mpegURL"
            : "video/mp4"
        if let runTimeTicks = castItem.baseItem.runTimeTicks {
            builder.streamDuration = TimeInterval(runTimeTicks) / 10_000_000
        }

        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(castItem.baseItem.name ?? "", forKey: kGCKMetadataKeyTitle)
        builder.metadata = metadata

        let loadOptions = GCKMediaLoadOptions()
        loadOptions.playPosition = adjustedSeconds

        // Listen for media status updates so the iOS UI (position, play/pause state)
        // stays in sync with the receiver.
        remoteMediaClient.add(self)

        let request = remoteMediaClient.loadMedia(builder.build(), with: loadOptions)
        request.delegate = self
        activeLoadRequest = request
    }

    /// Reconstruct the `MediaPlayerItem` for Cast using our picker's bitrate
    /// tier and the user's global compatibility mode. Returns `nil` on
    /// failure so the caller can fall back to the original item.
    @MainActor
    private func rebuildItemForCast(from item: MediaPlayerItem) async -> MediaPlayerItem? {
        let requested = pendingBitrate ?? Defaults[.VideoPlayer.Playback.appMaximumBitrate]
        let compatibility = Defaults[.VideoPlayer.Playback.compatibilityMode]
        do {
            return try await MediaPlayerItem.build(
                for: item.baseItem,
                mediaSource: item.mediaSource,
                videoPlayerType: .swiftfin,
                requestedBitrate: requested,
                compatibilityMode: compatibility
            )
        } catch {
            return nil
        }
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

        // GoogleCast SDK uses Objective-C NSError-by-reference, not Swift throws.
        channel.sendTextMessage(jsonString, error: nil)
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
            // Clear picker overrides so the next Cast attempt starts from
            // a clean slate. Otherwise, if the user cancelled the device
            // dialog or the session ended early, the *next* picker
            // confirm could be ignored / overridden by lingering values
            // from this one.
            self.pendingBitrate = nil
            self.pendingAudioStreamIndex = nil
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

// MARK: - GCKRequestDelegate

extension CastManager: GCKRequestDelegate {

    func requestDidComplete(_ request: GCKRequest) {
        DispatchQueue.main.async {
            self.lastLoadError = nil
            self.activeLoadRequest = nil
        }
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        DispatchQueue.main.async {
            self.lastLoadError = "Cast load failed: \(error.localizedDescription) (code \(error.code))"
            self.activeLoadRequest = nil
        }
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        DispatchQueue.main.async {
            self.lastLoadError = "Cast load aborted (reason \(abortReason.rawValue))"
            self.activeLoadRequest = nil
        }
    }
}
