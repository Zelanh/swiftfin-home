# Notes for future self (and any future Claude sessions)

This file is **not part of the upstream Swiftfin project**. It exists only
for this Chromecast-focused fork (`swiftfin-home`) as a notepad. It is plain
markdown — won't break any build — and is safe to ignore from `git` if you
prefer to keep it untracked.

If you want to keep it private, add this line to `.gitignore`:
```
NOTES.md
```

If you want it shared as project documentation, just `git add NOTES.md`
like any other file.

---

## Background

This fork of Swiftfin adds **Chromecast support** to the official iOS app.
All the code was written by a non-developer with heavy AI assistance
(Claude, between June 2-4 2026). It is **not intended for upstream merge**
and explicitly does NOT follow Jellyfin's "no AI without expertise" policy
for the main project — it's a personal-use fork.

### High-level architecture of what was added

1. **`Shared/Services/CastManager.swift`** — Singleton (`Container.castManager`)
   that wraps `GCKCastContext`. Owns the active `GCKCastSession`, registers a
   custom-namespace channel for the Jellyfin receiver, sends `Identify` +
   `PlayNow` commands, and exposes `@Published` state (`isSessionActive`,
   `castPlayerState`, etc.) for SwiftUI to observe.

2. **`Shared/Objects/MediaPlayerManager/MediaPlayerProxy/MediaPlayerProxy+Chromecast.swift`**
   — `ChromecastMediaPlayerProxy` conforming to `VideoMediaPlayerProxy`.
   When a Cast session is active the `VideoPlayer` swaps `manager.proxy`
   from VLC to this; play/pause/seek go through `CastManager`, which proxies
   to `GCKRemoteMediaClient`.

3. **`Swiftfin/Views/Cast/CastButtonView.swift`** — The button shown in the
   playback navigation bar. SwiftUI-only (no `UIViewRepresentable`).

4. **`Swiftfin/Views/Cast/CastQualityPickerView.swift`** — Sheet shown
   before a Cast session starts. User picks audio track + `maxBitrate`.
   Persisted via `Defaults[.castMaxBitrate]`. The chosen values are stashed
   on `CastManager.pendingMaxBitrate` / `pendingAudioStreamIndex` and
   consumed by the next `load(item:)`.

5. **`Swiftfin/App/AppDelegate.swift`** — Initializes `GCKCastContext` with
   the Jellyfin receiver app ID (`F007D354`).

6. **`Cartfile` + `ChromeCastFramework.json`** — Pulls the GoogleCast SDK
   binary via Carthage (`--use-xcframeworks`). Linked to the iOS target
   manually in `project.pbxproj` (the framework reference was originally
   orphaned, not added to "Link Binary With Libraries" — fixed in
   commit `b53da6a`).

### Critical message-protocol detail

The Jellyfin Chromecast receiver does **NOT** intercept standard CAF
`loadMedia` requests. It listens for custom messages on:

```
namespace: urn:x-cast:com.connectsdk
```

The `PlayNow` payload shape (verified against `jellyfin-web`'s
`chromecastPlayer/plugin.js`):

```json
{
    "command": "PlayNow",
    "serverAddress": "https://your.jellyfin.server",
    "accessToken": "...",
    "userId": "...",
    "deviceId": "iOS_<vendorUUID>",
    "serverId": "...",
    "serverVersion": "10.x.y",
    "receiverName": "Living room",
    "options": {
        "items": [<full BaseItemDto as PascalCase JSON>],
        "startPositionTicks": 0,
        "mediaSourceId": "...",
        "audioStreamIndex": -1,
        "subtitleStreamIndex": -1,
        "maxBitrate": 5000000
    }
}
```

An `Identify` handshake (same shape, `command: "Identify"`, empty `options`)
must be sent **before** `PlayNow`, immediately after `sessionManager(_:didStart:)`.
Without it the receiver may ignore the load.

---

## TODO: Refactor `CastButtonView` to "Option 3" (use real `GCKUICastButton`)

### Why

The current implementation is a pure SwiftUI `Button`. It works but it
gives up some niceties that the SDK's own `GCKUICastButton` provides:

- Animated "connecting" state (the dot/wave between idle and active)
- Auto-discovery via the button's UIKit lifecycle (`didMoveToWindow`)
- Auto-visibility when no devices are around
- Native accessibility hints per state
- Any future cosmetic improvements Google ships in `GCKUICastButton`

We compensate manually with `discoveryManager.startDiscovery()` in
`CastManager.init()` and an `.opacity` rule on `hasAvailableDevices`,
but those are essentially re-implementations of behaviour the SDK
already has.

### What `GCKUICastButton` gives us that we want to keep

- `triggersDefaultCastDialog: Bool` — when `false`, the button still
  fires its UIKit target/action on tap but does **not** auto-open the
  cast dialog. This is the official extension point for "intercept the
  tap and do something custom first".
- Built-in icon state machine driven by `GCKSessionManager` state.
- Built-in `startDiscovery` / `stopDiscovery` in the button's lifecycle
  callbacks (specifically `didMoveToWindow`).

### Refactor sketch

```swift
import GoogleCast
import SwiftUI

struct CastButtonView: View {

    @InjectedObject(\.castManager) private var castManager: CastManager
    @InjectedObject(\.mediaPlayerManager) private var manager: MediaPlayerManager
    @State private var showingPicker = false

    var body: some View {
        _CastButtonBridge(onTap: handleTap)
            .frame(width: 28, height: 28)
            .sheet(isPresented: $showingPicker) {
                if let item = manager.playbackItem {
                    CastQualityPickerView(
                        item: item,
                        onConfirm: { bitrate, audioIndex in
                            castManager.pendingMaxBitrate = bitrate
                            castManager.pendingAudioStreamIndex = audioIndex
                            showingPicker = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                _ = GCKCastContext.sharedInstance().presentCastDialog()
                            }
                        },
                        onCancel: { showingPicker = false }
                    )
                }
            }
    }

    private func handleTap() {
        if castManager.isSessionActive {
            _ = GCKCastContext.sharedInstance().presentCastDialog()
        } else if manager.playbackItem != nil {
            showingPicker = true
        } else {
            _ = GCKCastContext.sharedInstance().presentCastDialog()
        }
    }
}

/// UIKit bridge: the real `GCKUICastButton` with its auto-discovery and
/// state animations, but with the default-dialog auto-trigger disabled so
/// we can route the tap through our SwiftUI flow.
private struct _CastButtonBridge: UIViewRepresentable {

    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        button.tintColor = .white
        button.triggersDefaultCastDialog = false
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleTap),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func handleTap() { onTap() }
    }
}
```

### Things to remove when this refactor lands

- The `discoveryManager.startDiscovery()` line in `CastManager.init()`
  (the real button will handle it).
- The `.onAppear { ... startDiscovery() }` belt-and-braces in
  `CastButtonView` (same reason).
- The `.opacity` / `.disabled` rules based on `hasAvailableDevices` —
  the real button hides itself.
- Probably `hasAvailableDevices` becomes dead code unless something
  else reads it. Check before deleting.

### Risks / things to test after the refactor

- Tinting still white (`.tintColor = .white` on the UIView).
- Tap event firing through the `Coordinator` reliably (test by tapping
  rapidly).
- Sheet presents over the bridge view (SwiftUI bridges + sheets can be
  finicky; if the sheet won't show, hoist the `.sheet` modifier to a
  parent that owns `showingPicker` instead of putting it on the bridge).
- iPad behaviour — `presentCastDialog()` is a `UIAlertController`-style
  presentation; on iPad it needs a `sourceView`/`sourceRect` for the
  popover. The SDK usually handles this, but verify.
- VoiceOver still announces the button states.

### Estimated cost

~60-80 added lines, 0-1 builds. The hardest part is just making sure
the SwiftUI `.sheet` works with the `UIViewRepresentable` bridge.

---

## 🐛 Confirmed Bug: Cast Quality Picker — visual selection ≠ sent value

**Status:** Confirmed by user testing on 2026-06-06. Reproducible.

**Symptom:**
- User opens Cast quality picker
- Visually sees "1.5 Mbps" tier selected (radio button on that row)
- Even after deliberately re-selecting (tap another, tap 1.5 again)
- Confirms with "Start"
- The actual `maxBitrate` reaching the Jellyfin receiver is DIFFERENT
  from 1.5 Mbps — pattern suggests value gets stuck on whatever was
  in `Defaults[.castMaxBitrate]` BEFORE the user's most recent selection

**Empirical evidence:**
- User selected "1.5 Mbps" → FFmpeg output was 12.27 Mbps (matches the
  "3 Mbps tier → ~11-12 Mbps" pattern, not the "1.5 Mbps tier → ~9 Mbps"
  pattern we'd expect)
- Confirmed via Jellyfin server log + FFmpeg log on 2026-06-06 11:36

**Suspected root causes** (without ability to build/trace, listed in order
of likelihood):
1. SwiftUI `.pickerStyle(.inline)` with `Int` tags has known desync issues
   between visual selection and `@State`-bound value
2. The `Button("Start")` action may read `selectedBitrate` before SwiftUI
   has committed the last picker tap to `@State`
3. `Defaults[.castMaxBitrate]` may hold a stale value that contaminates
   `@State` init across multiple sheet presentations

**Proposed fix** (to apply when GitHub Actions minutes are available):

```swift
// In CastQualityPickerView.swift

// 1) Validate the persisted value falls inside the known tier list
init(...) {
    let savedBitrate = Defaults[.castMaxBitrate]
    let validBitrate = Self.bitrateOptions.first(where: { $0.bps == savedBitrate })?.bps
                       ?? Self.bitrateOptions.first!.bps
    self._selectedBitrate = .init(initialValue: validBitrate)
}

// 2) Capture @State value locally before any side effect in Start
Button("Start") {
    let confirmedBitrate = selectedBitrate
    let confirmedAudio = selectedAudioIndex

    // TEMP DIAGNOSTIC — keep through next test, then remove
    print("[CastPicker] confirming maxBitrate=\(confirmedBitrate)")

    Defaults[.castMaxBitrate] = confirmedBitrate
    onConfirm(confirmedBitrate, confirmedAudio)
}

// 3) Consider switching from .pickerStyle(.inline) to .menu or
//    .navigationLink — both have more reliable @State binding behaviour
```

**Workaround for users until the fix lands:**
- Force-quit Swiftfin (swipe-up app switcher kill) between Cast sessions
- This guarantees fresh `@State` init and clean `pendingMaxBitrate` on
  `CastManager` singleton

---

## Other ideas for later

- **Mid-cast quality change**: currently you have to stop the cast and
  start again to change `maxBitrate`. Could expose the picker again
  during an active session by tapping the button (instead of opening the
  native dialog) and sending a fresh `PlayNow` to the same receiver.
  Receiver behaviour TBD — might restart the stream cleanly.
- **Subtitle picker**: same sheet could let the user pick a subtitle
  track for cast. Currently we just forward `item.selectedSubtitleStreamIndex`.
- **Cast from item info screen** (not only from inside the player) —
  user mentioned other apps do this. Requires a "phantom" `MediaPlayerItem`
  or refactoring how `CastManager.load` consumes its input.
- **Keepalive ping** to the Jellyfin server during cast — would help
  if the transcoder's kill-timer ever interrupts long sessions.
- **Multi-audio Atmos passthrough** — currently we let the receiver
  pick. Worth checking what jellyfin-chromecast does with EAC3 + Atmos.

---

## Conversation context

The Chromecast support work happened across multiple conversations with
Claude (Sonnet 4.5). The bulk of the protocol research, the
`com.connectsdk` namespace discovery, the `Identify` handshake, and the
`maxBitrate` debugging is documented in conversation transcripts dated
roughly June 2-4 2026.

If you (future you, or a future Claude session) want to refresh on any
of this: re-read this file plus the inline comments in
`CastManager.swift` and `CastButtonView.swift`. The "why" of every
non-obvious decision is in one of those three places.

---

## 📚 Deep-dive: how Streamyfin handles Chromecast (research 2026-06-07)

This section captures findings from reading the
[Streamyfin](https://github.com/streamyfin/streamyfin) source code
(local copy at `C:\swiftfin\streamyfin-develop`) to understand why
their cast bitrate selector "just works" while ours stuck on a fragile
hint-based protocol.

**TL;DR**: Streamyfin uses a **fundamentally different cast architecture**
than ours. They never touch the Jellyfin custom namespace
(`urn:x-cast:com.connectsdk`). Instead they negotiate a stream URL with
Jellyfin via REST API *first*, then play that URL on the Chromecast via
**standard CAF `loadMedia`**.

This single difference solves three of our problems at once:
1. Bitrate cap is honoured (URL has the bitrate baked in by Jellyfin
   itself, no "hint" the receiver can override).
2. Session cache invalidation is automatic (a new URL = a new playback
   session, full stop).
3. Quality changes work without leaving the player (the picker emits a
   new URL, `loadMedia` swaps the playing stream).

The trade-off: they don't get any Jellyfin-receiver-specific UI features
(custom branding, watchlist actions, etc.). They use whatever the
Chromecast's default CAF player renders, with their own metadata
embedded in `mediaInfo.metadata`.

### Streamyfin's bitrate model

`components/BitrateSelector.tsx` and `components/BitRateSheet.tsx`:

```typescript
export const BITRATES: Bitrate[] = [
  { key: "Max",       value: undefined },
  { key: "8 Mb/s",    value: 8_000_000, height: 1080 },
  { key: "4 Mb/s",    value: 4_000_000, height: 1080 },
  { key: "2 Mb/s",    value: 2_000_000 },
  { key: "1 Mb/s",    value: 1_000_000 },
  { key: "500 Kb/s",  value: 500_000 },
  { key: "250 Kb/s",  value: 250_000 },
];
```

Notes on what we should steal:
- **"Max" = `undefined`**, not `0`. Sending `undefined` (or omitting
  the parameter) lets Jellyfin pick the default; sending `0` is
  ambiguous — depending on the call site it could mean "no cap" or
  "force 0 bps".
- Their tiers go MUCH LOWER than ours (down to 250 kb/s). That's
  pragmatic for mobile / weak WiFi scenarios. Our floor of 1.5 Mbps
  is probably too aggressive for low-end use cases.
- They tag some tiers with a target `height` (1080), implying they
  may pass it to Jellyfin as an additional constraint. Worth
  investigating.

### Streamyfin's DeviceProfile pattern

`utils/profiles/chromecast.ts`:

```typescript
export const chromecast: DeviceProfile = {
  Name: "Chromecast Video Profile",
  MaxStreamingBitrate: 16_000_000,           // 16 Mbps hard ceiling
  MaxStaticBitrate: 16_000_000,
  MusicStreamingTranscodingBitrate: 384_000,
  CodecProfiles: [
    { Type: "Video", Codec: "h264" },
    { Type: "Audio", Codec: "aac,mp3,flac,opus,vorbis" },
  ],
  DirectPlayProfiles: [
    { Container: "mp4", Type: "Video", VideoCodec: "h264", AudioCodec: "aac,mp3,opus,vorbis" },
    // … audio-only entries …
  ],
  TranscodingProfiles: [
    {
      Container: "ts", Type: "Video",
      VideoCodec: "h264", AudioCodec: "aac,mp3",
      Protocol: "hls", Context: "Streaming",
      MaxAudioChannels: "2", MinSegments: 2,
      BreakOnNonKeyFrames: true,
    },
    // … more transcoding profiles …
  ],
  SubtitleProfiles: [{ Format: "vtt", Method: "Encode" }, …],
};
```

There's also a `chromecasth265.ts` variant for users who explicitly
opt in to H.265 (Chromecast Ultra supports it, default profile
doesn't). The `PlayButton` reads
`settings.enableH265ForChromecast` and picks the right profile.

**Key insight**: the `MaxStreamingBitrate` on the DeviceProfile is a
**hard cap** that the user's picker tier cannot exceed. Even if the
user picks "Max" (undefined → no per-call cap), the device profile
ceiling kicks in. That's a much safer pattern than what we do (no
ceiling, fully trust the user's pick + receiver's heuristics).

### Streamyfin's URL-negotiation flow

`utils/jellyfin/media/getStreamUrl.ts` is the canonical reference. Two
steps:

#### Step 1: ask Jellyfin "what URL should I play?"

```typescript
const res = await getMediaInfoApi(api).getPlaybackInfo(
  { itemId: item.Id! },
  {
    method: "POST",
    data: {
      userId,
      deviceProfile,            // ← chromecast profile from above
      subtitleStreamIndex,
      startTimeTicks,           // ← resume position in ticks
      isPlayback: true,
      autoOpenLiveStream: true,
      maxStreamingBitrate,      // ← user's picker choice
      audioStreamIndex,
      mediaSourceId,
    },
  },
);

const sessionId   = res.data.PlaySessionId;
const mediaSource = res.data.MediaSources?.[0];
```

The endpoint is `POST /Items/{itemId}/PlaybackInfo`. Jellyfin's
response includes:
- `PlaySessionId` — server-generated UUID for this playback. **The
  server generates it, not us.** This is what fixes the "session
  cache" issue: every call to `getPlaybackInfo` returns a NEW
  `PlaySessionId`, which means Jellyfin treats it as a new playback
  session and spins up a fresh transcode keyed to it.
- `MediaSources[0]` — includes the `TranscodingUrl` (when transcoding
  is required) and metadata about codecs, streams, etc. The
  `TranscodingUrl` ALREADY has `MaxStreamingBitrate` and the chosen
  audio/subtitle indices embedded in its query string.

#### Step 2: build the final playback URL

```typescript
function getPlaybackUrl(api, itemId, mediaSource, params): string {
  if (mediaSource?.TranscodingUrl) {
    // Server already built the URL with bitrate/audio/subs embedded.
    return `${api.basePath}${mediaSource.TranscodingUrl}`;
  }
  // … fallbacks for direct play and remote streams …
}
```

For our case (transcoded HDR 4K with bitrate caps), the
`TranscodingUrl` path will be hit every time.

### Streamyfin's actual cast send

`components/PlayButton.tsx`, inside the `handleNormalPlayFlow`
callback after the user picks Chromecast in the ActionSheet:

```typescript
// 1. Get a fresh URL with the chosen bitrate via Jellyfin REST
const data = await getStreamUrl({
  api,
  item,
  deviceProfile: enableH265 ? chromecasth265 : chromecast,
  startTimeTicks: item?.UserData?.PlaybackPositionTicks ?? 0,
  userId: user.Id,
  audioStreamIndex: selectedOptions.audioIndex,
  maxStreamingBitrate: selectedOptions.bitrate?.value,
  mediaSourceId: selectedOptions.mediaSource?.Id,
  subtitleStreamIndex: selectedOptions.subtitleIndex,
});

// 2. Standard CAF loadMedia. NO custom namespace. NO PlayNow JSON.
client.loadMedia({
  mediaInfo: {
    contentId:   item.Id,
    contentUrl:  data?.url,           // ← the URL from step 1
    contentType: "video/mp4",
    streamType:  MediaStreamType.BUFFERED,
    streamDuration: streamDurationSeconds,
    metadata: { /* movie / tvShow metadata with images */ },
  },
  startTime: startTimeSeconds,
});
```

That's the whole cast flow. No `urn:x-cast:com.connectsdk` channel.
No `Identify` handshake. No `PlayNow` JSON. Just standard
Chromecast CAF.

### What this means for our fork's quality picker bug

The bug we've been chasing (and failed to fully fix with `playSessionId`
on 2026-06-07) is structural to our chosen architecture:

- We send `maxBitrate` as one field inside a `PlayNow` payload on the
  custom namespace.
- The jellyfin-chromecast receiver parses our payload, calls Jellyfin's
  `getPlaybackInfo` *with its own DeviceProfile* (we don't supply one),
  and uses our `maxBitrate` only as a hint inside that call.
- The receiver's DeviceProfile sets ITS OWN `MaxStreamingBitrate`. The
  hint we send can move the result within that ceiling, but the
  ceiling itself is outside our control.
- Even more annoyingly, the receiver caches the `PlaySessionId` it gets
  from Jellyfin and reuses it for follow-up segment requests, so once
  a transcode is started it persists across our PlayNows of the same
  item. Sending our own `playSessionId` in `options` doesn't fix it
  because the receiver doesn't forward that field.

Streamyfin avoids ALL of this because the URL contains the bitrate as a
query-string parameter. Different URL = different playback session, no
ambiguity, no caching surprises.

### Two refactor paths

#### Path A — full architectural switch to "Streamyfin model"

Stop using the custom namespace entirely. New `CastManager.load(item:)`:

1. Call Jellyfin's `/Items/{itemId}/PlaybackInfo` via JellyfinAPI
   (already linked in the project) with a DeviceProfile that includes
   `MaxStreamingBitrate` derived from the picker.
2. Read `MediaSources[0].TranscodingUrl` from the response.
3. Build the absolute URL.
4. Use `GCKRemoteMediaClient.loadMedia(GCKMediaLoadRequestData)` with
   `GCKMediaInformation` containing that URL + metadata.

What we lose:
- The "Living Room" branded Jellyfin receiver UI on the TV
- Any future receiver-side features
- The current `Identify`/`PlayNow` machinery (delete it)

What we gain:
- Bitrate cap actually respected
- Session reuse problem disappears
- Mid-cast quality change is just "call `loadMedia` again with a new URL"

**Estimated cost**: 1–2 days of work. Mostly:
- Constructing the Swift equivalent of Streamyfin's DeviceProfile
  (probably from `DeviceProfile` in `JellyfinAPI`)
- Rewriting `CastManager.load` and the `MediaPlayerProxy+Chromecast`
- Removing the custom namespace machinery and channel handling
- Re-testing the whole cast flow

#### Path B — keep custom namespace, send our own DeviceProfile

Less invasive. Add a `DeviceProfile` object to the `options` we send
in PlayNow, with our chosen `MaxStreamingBitrate` baked in. The
receiver MIGHT respect it (some receivers do, jellyfin-chromecast
behaviour unverified). Not tested yet.

**Estimated cost**: 1–2 hours. But success uncertain — depends on
whether the receiver honours an app-supplied DeviceProfile or just
uses its own.

Worth trying Path B first as a low-cost experiment before committing
to the bigger Path A refactor.

### Where the user-facing picker lives in Streamyfin

Streamyfin puts the bitrate picker on the **item detail page**, not
inside the player. The flow is:

1. User opens a movie/episode detail page.
2. User picks audio, subs, bitrate via dropdowns on that page
   (`BitrateSelector` lives directly on `ItemContent.tsx`).
3. User taps the big "Play" button (`PlayButton.tsx`).
4. If a Chromecast is connected, an ActionSheet asks "Chromecast or
   Device?".
5. On Chromecast → `getStreamUrl` + `loadMedia` (as above).
6. On Device → navigate to the in-app player with the same params in
   the URL.

The user noted that our current flow (Cast button inside the player)
feels awkward because you have to start playing locally before you can
cast. Moving the Cast affordance to the item detail page, the way
Streamyfin does, would also fix this UX. Worth bundling with Path A.

### Key files referenced (in `streamyfin-develop`)

For future Claude sessions wanting to re-verify these findings:

| File | Purpose |
|---|---|
| `utils/profiles/chromecast.ts` | DeviceProfile constant for the Chromecast video profile |
| `utils/profiles/chromecasth265.ts` | DeviceProfile variant for H.265-capable Chromecasts |
| `utils/jellyfin/media/getStreamUrl.ts` | The REST-negotiation logic; calls `getPlaybackInfo` |
| `providers/PlaySettingsProvider.tsx` | Holds chosen bitrate / audio / subs and re-derives the URL |
| `components/BitrateSelector.tsx` | The dropdown UI on the item page |
| `components/BitRateSheet.tsx` | Alternative bottom-sheet UI (older / fallback?) |
| `components/PlayButton.tsx` | The actual "Play" button with the cast/device ActionSheet and `loadMedia` call |
| `components/Chromecast.tsx` | The icon-only Cast button (only triggers discovery + cast dialog, no quality logic) |

The clean separation of concerns is worth copying: discovery in one
component, quality picker in another, actual play-to-cast logic in a
third (the PlayButton).

### Things that surprised me while reading

- Streamyfin's `PlayButton` has an inline `CastButton` from
  `react-native-google-cast` that's rendered with `tintColor='transparent'`
  — they use it purely to satisfy the SDK's "a CastButton must exist
  somewhere or discovery breaks on Android" requirement, while
  displaying their own Feather `cast` icon next to it. Clever.
- The `getPlaybackInfo` call is identical for local playback and Cast
  playback — same code path, just different `deviceProfile`. That's
  why the picker selection works the same way in both contexts. We
  could share this too.
- Streamyfin commented out a `postFullCapabilities` block in
  `PlaySettingsProvider.tsx` — looks like they considered registering
  the device profile with Jellyfin at app start (so it'd apply to ALL
  subsequent calls) but backed out. Not sure why. Could be relevant if
  we hit subtle DeviceProfile issues later.

### ⚠️ IMPORTANT CAVEAT: Streamyfin fails to cast many movies (2026-06-08 update)

User reports that in real-world use, Streamyfin **fails to cast a lot
of content** that our fork casts successfully. Investigated with a
concrete example: Mufasa (2024, 4K WEBDL HEVC Dolby Vision profile
8.1, 25 Mbps, with SRT subtitles).

**With Streamyfin at "250 Kb/s":** Jellyfin starts a transcode chain
that scales down to **640×346** at **122 kbps**, with CUDA-based
**subtitle burn-in** via `alphasrc + subtitles + hwupload +
overlay_cuda`. The result is processed but either too low-bitrate to
play smoothly or saturates the GPU pipeline. Stream is unwatchable.

**With Streamyfin at "Max":** the transcode starts but never delivers
segments to the client. Jellyfin's kill timer eventually terminates
the job (`Transcoding kill timer stopped for JobId ... Killing
transcoding`, FFmpeg exits clean with code 0). Likely cause: the
Chromecast receiver can't make sense of the DV profile 8.1 negotiation
that Streamyfin's permissive Max-bitrate request produces, so it never
requests the first segment.

**Why our fork plays the same movie fine:** the jellyfin-chromecast
receiver (which we delegate to via PlayNow) has its own DeviceProfile
that's more permissive than Streamyfin's hardcoded one. It probably:

- Allows HEVC direct-stream (our path: video isn't re-encoded for the
  Chromecast Ultra, which can decode HEVC natively)
- Declares more native subtitle formats (srt, vtt, ass) so SRT doesn't
  need burn-in
- Leaves HDR tonemapping to the Chromecast / TV hardware

**Root cause of Streamyfin's failure** (verified by reading
`utils/profiles/chromecast.ts`):

```typescript
SubtitleProfiles: [
  { Format: "vtt", Method: "Encode" },  // ← only declares vtt
  { Format: "vtt", Method: "Encode" },  // ← duplicate; "Encode" = burn in
],
```

`Method: "Encode"` tells Jellyfin: "if the subtitle isn't this format,
**burn it into the video**". Combined with the lack of any other
subtitle format declarations, every SRT/PGS/ASS subtitle triggers a
CUDA-heavy burn-in pipeline. Streamyfin's setup is genuinely broken,
not a quirk of the underlying Cast architecture.

**Why this matters for our Path A consideration:**

The Cast architecture itself (REST negotiation + standard CAF
loadMedia) is **not** the cause of Streamyfin's failures. The cause is
their DeviceProfile content. If we adopt Path A, we **do not copy
their profile** — we design our own that's at least as permissive as
the one jellyfin-chromecast's receiver currently uses.

Concrete checklist for our hypothetical Path A DeviceProfile:

| Property | Streamyfin (avoid) | Ours (target) |
|---|---|---|
| `MaxStreamingBitrate` | 16_000_000 fixed | Configurable per user; default ≥ 20_000_000 |
| HEVC direct-stream | Only in `chromecasth265.ts` opt-in | Enabled by default for `Chromecast Ultra` family |
| `SubtitleProfiles` | vtt+Encode (forces burn-in) | vtt External + srt Embed + ass Embed |
| Tonemap responsibility | Forced server-side (`tonemap_cuda`) | Pass through to Chromecast when supported |
| `RemoteClientBitrateLimit` interaction | Hits silently | Surface to user if their User Policy is below the picker pick |

We can **read jellyfin-chromecast's hard-coded receiver
DeviceProfile** (search the receiver repo for `MaxStreamingBitrate`)
and port that to Swift as our starting point. That guarantees parity
with our current "everything plays" reliability.

**Server-side bottleneck also worth noting:** the user's Jellyfin
server has a User Policy `RemoteClientBitrateLimit: 10000000` (10 Mbps).
This applies even on local network and is invisible to clients —
they'll just get capped transcodes. Worth documenting in FAQ.md so
future user / future Claude doesn't waste time chasing a "client cap"
when the cap is in fact server-side.

### Decision principle for Path A vs Path B (updated 2026-06-08)

After the Streamyfin reliability findings, the right framing is:

- **Path A is correct architecturally** — URL-baked bitrate, no
  cache-reuse issues, clean separation of concerns.
- **Path A is risky if we copy a profile blindly** — Streamyfin's
  failures prove that the DeviceProfile is the load-bearing wall, not
  the protocol.
- **Path B is a useful low-cost experiment** — adding our own
  DeviceProfile to the PlayNow `options` and seeing whether the
  receiver honours it. If yes → we get bitrate cap respect without
  any architecture change. If no → we know the receiver overrides
  it, and Path A becomes the only solution.

Recommended order: **(1) Path B experiment** (1-2h) → **(2) if Path B
fails, Path A with a carefully designed profile, NOT copied from
Streamyfin.** Allocate at least half the Path A time to profile
research and validation against the user's actual library.
