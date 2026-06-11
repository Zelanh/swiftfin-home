# Swiftfin (Chromecast Fork) — Personal Use, AI-assisted

> ⚠️ **READ THIS FIRST**
>
> This is a **personal fork** of [Swiftfin](https://github.com/jellyfin/Swiftfin)
> with one feature added: **Chromecast support for iOS** (Cast button + quality
> picker).
>
> - The fork was **written by a non-developer with heavy AI assistance** (Claude).
> - It is **not endorsed by, affiliated with, or contributed back to the Jellyfin
>   project**. The official Swiftfin team explicitly does not accept AI-generated
>   contributions from non-experts, and that policy is respected here.
> - It is shared in case someone has the same need ("a Swiftfin iOS build with
>   a Cast button to my Chromecast Ultra"). **No support, no warranty, no
>   guarantee of being kept up to date with upstream.**
> - The upstream Swiftfin project is far better engineered than this fork.
>   If you can use the official app and don't specifically need Chromecast,
>   please do.
>
> This fork is released under the same MPL-2.0 license as Swiftfin.

---

## What this fork does

- Adds a Cast button to the iOS video player's navigation bar.
- Tapping the Cast button opens a **quality picker** sheet exposing the
  same bitrate tiers (including `Auto` with its network speed test) as
  Swiftfin's Settings → Playback Quality, then hands off to the standard
  GoogleCast device picker.
- Negotiates the stream with the Jellyfin server itself — the same
  `PlaybackInfo` negotiation local playback uses, but with a
  Chromecast-specific device profile (h264 + stereo AAC + MPEG-TS HLS)
  and the picker's bitrate baked into the resulting URL — and plays
  that URL on the **default Google media receiver** via standard CAF
  `loadMedia`. The picker tier is therefore a real cap, enforced by
  the server's transcoder.
- Persists the last-used bitrate tier so the picker pre-selects it next time.
- Switches the active `MediaPlayerProxy` from VLC to a Chromecast proxy when
  a session is active, so the existing playback controls (play/pause/seek)
  remain functional.
- Pauses local VLC playback when a Cast session starts and (best-effort)
  restores playback position when the Cast session ends.

## Usage notes & caveats

A few small things to know that aren't bugs but can surprise first-time
users. Skim these before assuming something is broken:

- **You must start playback first.** The Cast button lives inside the
  video player's navigation overlay, not on the browse / item info
  screens. Open a movie or episode, start playing it locally, *then* the
  Cast button becomes available in the player toolbar. Most other
  Jellyfin clients expose Cast from earlier screens; this fork does not
  (yet — see the TODO section at the end of the file).
- **The Cast button may take a few seconds to appear after entering the
  player.** Device discovery uses mDNS / Bonjour and only starts when
  the player loads. On a typical home WiFi the Chromecast is usually
  found in 1–3 seconds, but on a busy or congested network it can take
  10–30 seconds. If the button is missing, give it a moment before
  assuming something is broken.
- **The button hides itself if no Cast devices are discovered.** This
  matches the SDK's standard behaviour — you only see it once at least
  one Chromecast is on the same network as the iPhone. If you are sure
  your Chromecast is on and you still don't see the button after about
  a minute, check that:
  - The iPhone and the Chromecast are on the **same WiFi** (not a guest
    network).
  - Your network does not block mDNS / Bonjour traffic (some VLAN
    configurations or "AP isolation" settings on the router do).
  - The Chromecast itself shows up in the Google Home app on the same
    iPhone — if it does not, the issue is upstream of this app.
- **Cancelling the device picker keeps your last chosen quality.** If
  you open the quality picker, choose a bitrate, then back out of the
  native device dialog without picking a device, your chosen bitrate is
  still remembered for the next try. This is intentional and matches
  how Streamyfin behaves.
- **The picker tier is the total stream budget, video + audio.**
  Jellyfin splits it: picking `720 Kbps` yields roughly ~336 kbps of
  video plus the audio track. If a movie stutters on a higher tier,
  drop one or two steps and try again — the cap is enforced exactly.
- **The TV shows Google's standard player, not a Jellyfin-branded UI.**
  Since v1.3.0 the fork casts to the default Google media receiver, so
  the idle screen and player chrome on the TV are Google's. Cosmetic
  only.
- **Cast audio is stereo.** The Chromecast device profile downmixes
  multichannel tracks to 2.0 AAC for maximum receiver compatibility.
  5.1 / Atmos passthrough is a possible future improvement.
- **Subtitles are burned into the video server-side.** The cast stream
  carries the item's current subtitle selection rendered into the
  picture (this is also how Streamyfin handles cast subtitles). Burn-in
  costs some extra GPU on the server while a sub track is active.

## What this fork does NOT do

- **No tvOS Chromecast support.** The GoogleCast SDK is iOS-only for
  Carthage binaries; the tvOS target is unchanged.
- **No subtitle track override in the cast picker.** The cast stream
  uses the item's current subtitle selection, burned in server-side.
- **No audio track override on cast (v1.3.0).** The picker still shows
  an audio selector, but since the v1.3.0 architecture change the
  selection is not yet forwarded into the negotiated stream — the cast
  plays the item's default/selected audio. Known limitation, planned
  for a patch release.
- **No mid-cast quality change.** To change the bitrate during a cast
  you have to stop and start again.
- **No Cast queue management.** Single-item casts only (the next
  episode in a queue is loaded automatically, but there's no
  PlayNext/PlayLast control).
- **No keepalive ping** to the server during long sessions. If the
  Jellyfin transcoding throttle/kill timer is too aggressive, playback can
  interrupt. Tune the server settings, not the client.
- **No DRM, no FairPlay.** Standard Swiftfin scope.
- **No automated signing in CI.** The IPA artifact produced by GitHub
  Actions is **unsigned**. You re-sign it yourself with Sideloadly /
  3uTools / AltStore / Apple Developer cert.
- **Not synced with upstream.** Whatever Swiftfin version this was forked
  from is what it stays at unless someone manually rebases.

---

## Technical changes vs. upstream

### Dependencies added

| Dependency | Method | Used for |
|---|---|---|
| GoogleCast SDK 4.8.3 | Carthage binary (`Cartfile` entry `binary "ChromeCastFramework.json"`) | iOS Cast session management, channels, native dialog |

`ChromeCastFramework.json` is a local Carthage binary manifest that points
to `https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.3_dynamic.zip`.

### Source files added

```
Shared/Services/CastManager.swift
Shared/Objects/MediaPlayerManager/MediaPlayerProxy/MediaPlayerProxy+Chromecast.swift
Swiftfin/Views/Cast/CastButtonView.swift
Swiftfin/Views/Cast/CastQualityPickerView.swift
```

### Source files modified

```
Swiftfin/App/AppDelegate.swift                 # GCKCastContext bootstrap (default Google receiver)
Shared/Components/VideoPlayer.swift            # proxy switching on isSessionActive
Swiftfin/Views/VideoPlayerContainerView/PlaybackControls/Components/NavigationBar/NavigationBar.swift  # CastButtonView placement
Shared/Extensions/JellyfinAPI/DeviceProfile.swift  # additive: buildChromecast() profile
Shared/Objects/MediaPlayerManager/MediaPlayerItem/MediaPlayerItem+Build.swift  # optional customDeviceProfile: param
Cartfile                                       # ChromeCastFramework binary
```

### Project file changes (`Swiftfin.xcodeproj/project.pbxproj`)

- Added `GoogleCast.xcframework` as a linked + embedded framework to the
  Swiftfin iOS target. (The file reference for `GoogleCast.xcframework`
  was originally orphaned — present in the navigator but not in
  "Link Binary With Libraries". The fix added two `PBXBuildFile` entries
  and references in both the `PBXFrameworksBuildPhase` and the
  `PBXCopyFilesBuildPhase` (Embed Frameworks) for the iOS target only.)

### CI / build changes (`.github/workflows/build-ios.yml`)

A new workflow that produces an unsigned IPA artifact. Key differences
from the upstream `ci.yml` (which is left untouched):

- Triggers on `push` to `main` and `feature/**` branches.
- Selects **Xcode 26.3** on `macos-15` runners (it ships with iOS 26.2 SDK).
- Trusts Swift macros for headless CI:
  ```
  defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
  defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
  ```
- Installs `swiftgen swiftformat swiftlint` via brew (the Swiftfin build
  phases emit `error:` if missing).
- `carthage update --use-xcframeworks --cache-builds`.
- Pre-resolves SPM packages with `xcodebuild -resolvePackageDependencies`
  using the default derived-data path.
- **Patches Nuke 13.0.2**: replaces `nonisolated deinit` with `deinit` in
  all `.swift` files under
  `~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/Nuke`.
  Xcode 26.3's Swift compiler rejects the `nonisolated deinit` syntax
  in Swift 5 language mode; replacing with plain `deinit` is semantically
  equivalent for Swift 5 builds.
- Builds via `bundle exec fastlane buildLane` (matching the upstream
  Swiftfin `ci.yml`). This was necessary because direct `xcodebuild build`
  invocations failed to produce `CasePaths.swiftmodule` for iOS (it was
  only built for the macOS host target), which made `StatefulMacros` fail
  to import. Fastlane's `buildApp` somehow handles the build graph
  correctly. Empirical.
- Bumps `FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT` to 60 (Fastlane's 3-second
  default is too aggressive for cold CI runners).
- Ensures `fastlane/FastlaneRunner` is executable before invoking
  (`chmod +x`).
- Packages the resulting `.app` as an IPA and uploads as an artifact.

---

## Architecture

### Cast session lifecycle

```
User taps Cast button in player overlay
        |
        v
CastButtonView shows CastQualityPickerView (sheet)
        |
        v
User picks audio + bitrate, confirms
        |
        v
CastManager.pendingBitrate / pendingAudioStreamIndex set
        |
        v
GCKCastContext.presentCastDialog() (native device picker)
        |
        v
User picks a Chromecast device -> GoogleCast SDK starts a GCKCastSession
        |
        v
GCKSessionManagerListener.sessionManager(_:didStart:) fires
-> CastManager.isSessionActive = true (@Published)
        |
        v
VideoPlayer.onChange(of: isSessionActive) swaps manager.proxy to
ChromecastMediaPlayerProxy, pauses local VLC, calls castManager.load(item:)
        |
        v
CastManager.load() rebuilds the MediaPlayerItem via
MediaPlayerItem.build(requestedBitrate: pendingBitrate ?? globalDefault,
customDeviceProfile: .buildChromecast()) — the same getPostedPlaybackInfo
negotiation local play uses. Jellyfin returns a fresh PlaySessionID and
a stream URL (TranscodingUrl or direct) with the picker's cap baked in.
        |
        v
CastManager hands that URL to the receiver via standard CAF loadMedia
(GCKMediaInformation: contentURL, HLS/mp4 contentType, title metadata)
        |
        v
The default Google media receiver fetches the URL and plays it.
An idempotency guard skips the load if the receiver is already playing
the same item (prevents re-casts when the app returns to foreground).
        |
        v
GCKRemoteMediaClient delivers media status updates -> CastManager
publishes castPlayerState / currentCastPosition -> SwiftUI reacts.
```

### Receiver & stream negotiation

Since v1.3.0 the fork casts to the **default Google media receiver**
(`kGCKDefaultMediaReceiverApplicationID`) and controls quality by
negotiating the stream URL itself, exactly like local playback does:
`POST /Items/{id}/PlaybackInfo` with a Chromecast `DeviceProfile`
(h264 video, stereo AAC, HLS with MPEG-TS segments, subtitles via
server-side burn-in) plus the picker's `MaxStreamingBitrate`. The
receiver plays whatever URL it's given — there is no renegotiation
layer that can override the user's choice.

> **Historical note.** v1.0.0–v1.2.0 instead delegated to the official
> Jellyfin Chromecast receiver (app ID `F007D354`) via its custom
> message protocol (`urn:x-cast:com.connectsdk`, `Identify` +
> `PlayNow` JSON). That receiver renegotiates the stream with its own
> device profile and bandwidth detection, which is why the quality
> picker couldn't be made authoritative under that architecture. The
> protocol details remain documented in this file's git history
> (v1.2.0 and earlier) for anyone who needs them.

### Quality picker

`CastQualityPickerView` is a SwiftUI sheet with two pickers:

1. **Audio track** — bound to `selectedAudioIndex: Int?`, tagged with each
   `MediaStream.index` from `item.audioStreams`.
2. **Max bitrate** — list of `Button` rows over `PlaybackBitrate.allCases`,
   so the tiers exposed to the user are exactly the ones in Swiftfin's
   global Settings → Playback Quality picker (`.auto`, `.max`,
   `.mbps120`, `.mbps80`, …, `.kbps420`), with the same localized
   labels via `PlaybackBitrate.displayTitle`. `.auto` triggers the same
   network speed test that local playback uses.

The selected `PlaybackBitrate` is persisted in `Defaults[.castBitrate]`
on confirm so the next picker session pre-selects it. The audio
override is **not** persisted (it's per-cast).

The picker's values are stashed on the `CastManager` singleton's
`pendingBitrate: PlaybackBitrate?` and `pendingAudioStreamIndex`
properties. The next `load(item:)` reads `pendingBitrate` and feeds it
into `MediaPlayerItem.build(requestedBitrate:)`. As of v1.3.0,
`pendingAudioStreamIndex` is **not yet forwarded** into the negotiated
stream (see "What this fork does NOT do") — the audio selector is
currently cosmetic. Both values are cleared in
`sessionManager(_:didEnd:)` so a cancelled or interrupted session
can't leak stale values into the next cast attempt.

### Why a custom button instead of `GCKUICastButton`

The original implementation wrapped `GCKUICastButton` (a UIKit class) in
a `UIViewRepresentable`. To inject a quality picker before the native
device dialog, we would have needed to set
`triggersDefaultCastDialog = false` on the UIKit button, intercept its
target/action, and bridge the tap to SwiftUI state. That works but it
forces the rest of the integration (sheet presentation, visibility,
icon-state mirroring) through a Coordinator + bindings dance.

Replacing the button with a plain SwiftUI `Button` was simpler. The
side effects we lost (auto-discovery via `didMoveToWindow`, auto-hide
when no devices, connecting-state icon animation) are re-implemented
manually:

- `CastManager.init()` calls `discoveryManager.startDiscovery()`.
- `CastButtonView.onAppear` calls `startDiscovery()` again as a no-op
  safety net (`startDiscovery` is idempotent).
- `.opacity()` and `.disabled()` modifiers gate visibility on
  `castManager.hasAvailableDevices || castManager.isSessionActive`.
- The icon switches between `"tv"` and `"tv.fill"` based on
  `isSessionActive` (no connecting animation).

The native cast dialog (volume slider, scrubbing, stop, etc.) is
unchanged — it's a separate `UIViewController` invoked via
`GCKCastContext.sharedInstance().presentCastDialog()`.

A refactor back to `GCKUICastButton` with `triggersDefaultCastDialog = false`
is sketched out in `NOTES.md` (not part of the published fork) and would
restore the cosmetic features. PRs welcome but not promised.

---

## Installation

### Quick install (no build required)

If you just want the IPA without cloning and building anything:

1. Go to the **[Releases page](https://github.com/Zelanh/swiftfin-home/releases)**.
2. Pick the most recent release.
3. Under **Assets**, download `Swiftfin-Chromecast.ipa`.
4. **(Strongly recommended)** Verify the SHA-256 hash of what you
   downloaded against the value published in the release notes:
   - Windows (PowerShell): `Get-FileHash Swiftfin-Chromecast.ipa -Algorithm SHA256`
   - macOS / Linux: `shasum -a 256 Swiftfin-Chromecast.ipa`
   If the hash does **not** match, do not install — the file may have
   been tampered with in transit.
5. **The IPA is unsigned** — you cannot install it on an iPhone as-is.
   You must sign it yourself with one of the methods listed under
   [Signing & installing the IPA](#signing--installing-the-ipa) below.
   This is **mandatory** and a consequence of how Apple's app signing
   works, not a limitation of this fork.

> 🔍 **About release provenance.** Releases are normally published from
> GitHub Actions runs in this repository (the `.github/workflows/build-ios.yml`
> workflow). Each release's description tells you the exact run it was
> built from, so anyone can trace the binary back to its commit. When the
> monthly Actions allowance is exhausted, the most recent build's IPA
> may be uploaded manually — this is always disclosed in the release
> notes. If you want extra assurance, fork this repository and build the
> same commit yourself; the result should be bit-identical (modulo
> timestamps embedded in the binary).

### Building from source

If you would rather build the IPA yourself (for example, to modify the
code or to keep a continuously fresh artifact):

1. Fork or clone this repo.
2. Push to a branch that triggers the workflow (`main` or `feature/**`).
3. Wait for the GitHub Actions workflow to finish (10–15 minutes on
   `macos-15` runners).
4. Download the `Swiftfin-Chromecast-<number>` artifact from the run
   summary. The zip contains `Swiftfin-Chromecast.ipa`.
5. Sign and install per the section below.

### Signing & installing the IPA

The artifact is **unsigned**. To install on a device you need one of:

| Method | Cost | App lifetime | Setup effort |
|---|---|---|---|
| Free Apple ID via standard sideloading tools | Free | 7 days | Easiest |
| Community auto-refresh tools (e.g. AltStore-like) | Free | Refreshed periodically while infrastructure is reachable | Medium |
| Apple Developer Program + Ad Hoc | $99/year | 1 year | One-time setup, easiest long-term |
| TestFlight (requires Developer Program) | $99/year | 90 days per build | Medium |

> ⚠️ **Choose your signing path carefully.** The third-party tools that
> exist for sideloading with a free Apple ID are widely used and rely on
> Apple's own developer APIs, but Apple has at times labeled some of them
> as "out of policy". They are not prohibited by Jellyfin or by this fork,
> but it is your responsibility to review the terms of service of any tool
> you choose and use it at your own risk. The only path that has zero
> ambiguity is the official **Apple Developer Program**.

This fork's GitHub Actions workflow could be extended to sign the IPA in
CI if you have a Developer Program account — that's an exercise left to
the reader (or a future commit).

---

## License & attribution

- Swiftfin and the additions in this fork are licensed under
  [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/).
- All upstream copyrights are preserved (`Copyright © 2026 Jellyfin &
  Jellyfin Contributors`).
- The GoogleCast iOS SDK is © Google LLC, distributed under Google's
  iOS SDK license terms. This fork only references it as a Carthage
  binary; the binary is not redistributed here.
- "Jellyfin" and the Jellyfin logo are trademarks of the Jellyfin
  project. This fork uses them only to indicate compatibility, not to
  claim affiliation.

---

## If you want to fix something or improve this

Open an issue or a PR. **No promises about response time or merge** —
this is a personal-use fork. If you spot something genuinely broken or
have a cleaner approach to anything described above, the AI did its
best but the AI is not a Swift engineer. Improvements are welcome.

If you spot something that the **upstream Swiftfin team** could benefit
from (a protocol detail, a build fix, a Carthage tweak), please consider
opening it as an issue in the upstream repo rather than just here — it
helps them more than it helps this fork.

---

## Note to the Jellyfin / Swiftfin maintainers

If you are part of the Jellyfin or Swiftfin project and you have any
concerns about this fork — wording, naming, scope, the AI-assisted
nature of the changes, anything — please open an issue here or reach
out directly via the contact details in the GitHub profile. I will
take down, rename, or modify whatever you ask without argument.

This fork exists because the upstream iOS app does not currently ship
Chromecast support and one specific household needed it. It is not an
attempt to fork the project in any meaningful sense, to compete with
upstream, to suggest that AI-generated code belongs in your project,
or to claim any expertise. It is a personal-use build, made public
only in case someone else has the same narrow need.
