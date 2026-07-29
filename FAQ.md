# FAQ — Known issues and workarounds

This document lists currently-known bugs in this fork and the workarounds
until they are fixed. Only issues that are **reliably reproducible and
empirically verified** are listed here — speculative or unconfirmed
issues are not.

If you are using a build downloaded from the
[Releases page](https://github.com/Zelanh/swiftfin-home/releases), the
versions noted under each issue apply to you.

If a bug you hit is not listed below, feel free to open an issue (but
please remember this is an AI-assisted personal-use fork with no SLA —
see [FORK_README.md](./FORK_README.md)).

---

## 🟢 The Cast button doesn't appear after launching Swiftfin

**Affected versions:** v1.0.0. **Fixed in:** v1.1.0 (and current `main`).

### Symptom (v1.0.0)

You open Swiftfin (fresh launch), start playing a movie, and the Cast
button (TV icon) is missing from the player toolbar. Even after waiting
30+ seconds, it does not appear. The Chromecast IS on the same WiFi —
you can verify by opening Google Home, which finds the device in
seconds.

### Workaround for v1.0.0 (reliably repeatable)

1. Minimise Swiftfin (don't force-quit — just background it)
2. Open the **Google Home** app on the iPhone
3. Wait until Google Home shows your Chromecast in its device list
4. Return to Swiftfin
5. The Cast button now appears in the player toolbar

This works every time. The trigger is opening Google Home — it is what
makes the difference, not just any other app.

### Status

✅ **Fixed.** Verified on iPhone 14 against a Chromecast Ultra: the
button now appears within seconds of entering the player on a cold
start, without needing the Google Home workaround.

The fix kicks `GCKDiscoveryManager.startDiscovery()` from
`AppDelegate.didFinishLaunchingWithOptions` (instead of waiting for the
first `CastManager` lookup), and re-arms a stop/start discovery cycle
on `scenePhase == .active` from `CastButtonView`. This gives the iOS
Bonjour/mDNS subsystem its earliest possible chance to populate the
discovery cache before the user reaches the player.

If you are still on a v1.0.0 IPA, the workaround above still applies.
Upgrade to v1.1.0 or later to stop needing it.

---

## 🟢 The quality picker sometimes sends a different value than what is visually selected

**Affected versions:** v1.0.0, v1.1.0, v1.2.0 (partial). **Fully fixed in:** v1.3.0 (and current `main`).

### Symptom (v1.0.0–v1.2.0)

You tap the Cast button. The quality picker sheet appears, with one of
the tiers already shown selected (the radio button is on it). You tap
**Start** to confirm.

On the server side, the resulting transcoding bitrate **does not
correspond to the tier you saw selected**. For example, with **1.5 Mbps
visually marked**, the resulting FFmpeg `-b:v` came out at ~12 Mbps —
i.e. a much higher tier than the one shown to the user.

### What was actually happening (understood during the v1.3.0 work)

There were **two independent defects**, and untangling them took
several testing rounds:

1. **A real UI bug**: the SwiftUI inline picker could show a checkmark
   on one tier while the bound value held a different number. Fixed in
   v1.2.0.
2. **The deeper truth: in v1.0.0–v1.2.0 the picker value never
   reliably controlled the stream at all.** Those versions delegated
   playback to the Jellyfin Chromecast receiver, which renegotiates
   the stream with its own device profile and its own bandwidth
   detection. The bitrate that ended up on the server was the
   receiver's decision; the tier sent by the app was at best a hint.
   Apparent correlations observed in earlier testing (a pick "working"
   after re-selecting a tier, lower picks coinciding with lower
   transcodes) were the receiver's own bandwidth detection landing
   near the picked value **by coincidence**.

### Workaround for v1.0.0–v1.2.0

**There is none.** On those versions the bitrate is effectively chosen
by the Cast receiver, not by the picker — no input sequence changes
that. An earlier revision of this FAQ described a "reliably
repeatable" workaround (actively selecting a different tier before
confirming); it was based on the coincidental observations described
above and has been removed.

### Status

✅ **Two-stage fix. Both stages now in `main`.**

**Stage 1 — v1.2.0 — visual desync corrected.** The SwiftUI
`.pickerStyle(.inline)` Picker was replaced with explicit `Button` rows
so the visible checkmark and the bound `@State` value can no longer
disagree. The `asyncAfter(0.4)` before the native cast dialog was
replaced with the sheet's `onDismiss` callback so dialog presentation
waits on the real animation-end event. The picker's `pending*` overrides
on `CastManager` are cleared at session end so a cancelled or
interrupted session can't leak stale values into the next attempt.

After v1.2.0 shipped, follow-up testing surfaced that the visual fix
alone wasn't enough: the resulting transcode bitrate on the server
still didn't reliably match the Cast picker selection.

**Stage 2 — v1.3.0 — transcode bitrate now actually follows the
picker.** Root cause: the cast was delegated to the Jellyfin
Chromecast receiver app via its custom `PlayNow` protocol, and that
receiver **renegotiates the stream with Jellyfin using its own device
profile and its own bandwidth detection** — any bitrate the app sends
along is at best a hint, at worst ignored. No client-side change
could make the picker authoritative under that architecture.

v1.3.0 changes the architecture to mirror what local playback does:
`CastManager.load` rebuilds the `MediaPlayerItem` through the same
`getPostedPlaybackInfo` negotiation local play uses — but with a
Chromecast-specific device profile (h264 + stereo AAC + MPEG-TS HLS)
and the picker's `PlaybackBitrate` tier — and hands the resulting
stream URL directly to the **default Google media receiver** via
standard CAF `loadMedia`. The receiver just plays the URL; the cap is
baked into it by Jellyfin itself. Verified empirically: picking the
720 Kbps tier produces an FFmpeg transcode at ~336 kbps video
(total budget minus audio), picking 420 Kbps produces ~292 kbps, on
both HDR10 and Dolby Vision 8.1 sources.

The picker now exposes the same tiers (and the same `.auto` speed
test) as Settings → Playback Quality, acting as a per-cast override.

If you are still on a v1.0.0–v1.2.0 IPA: there is nothing you can do
client-side — the cast bitrate is the receiver's choice on those
versions. Upgrade to v1.3.0 or later for a picker that actually
controls the stream.

---

## 🟢 Changing the picker tier between two consecutive casts of the same item may not take effect

**Affected versions:** v1.0.0–v1.2.0. **Fixed in:** v1.3.0 (and current `main`).

### Symptom (v1.0.0–v1.2.0)

You cast a movie, stop the cast, then cast the **same movie again**
shortly after. Instead of starting a fresh stream, the receiver keeps
serving the **original transcode session** — same bitrate, same
server-side process.

The FFmpeg log file for the second cast shows:

- A high `-start_number` value (e.g. 237) instead of `0`.
- The same `-b:v` as the first session.

### Workaround for v1.0.0–v1.2.0 (empirically verified, with a caveat)

- **In Jellyfin, hit "Play from Beginning"** from the item's context
  menu before tapping Cast in Swiftfin. This does force a fresh
  transcode session. **Note, however**, that on those versions the new
  session's bitrate is still chosen by the Cast receiver's own
  bandwidth detection, not by the quality picker (see the previous
  entry) — so this workaround gets you a *fresh* stream, not a
  *chosen* one.

### Status

✅ **Fixed in v1.3.0**, as a side effect of the architecture change
described in the previous entry: `CastManager.load` now rebuilds the
`MediaPlayerItem` on **every** cast attempt via `MediaPlayerItem.build`,
which calls `getPostedPlaybackInfo` server-side each time. Each call
yields a fresh `PlaySessionID` and a transcoder freshly spun up with
the chosen cap, and the resulting URL is handed directly to the
receiver. Re-casting the same item with a different picker tier now
works on the first attempt — verified empirically (two consecutive
casts of the same movie at different tiers produced two fresh FFmpeg
sessions at ~336 kbps and ~292 kbps respectively).

If you are still on a v1.0.0–v1.2.0 IPA, the workaround above still
applies. Upgrade to v1.3.0 or later to stop needing it.

---

## 🟡 Poster artwork missing in the Cast mini controller and expanded controls

**Affected versions:** v1.3.0–v1.5.0.

### Symptom

While casting, the mini controller (bottom bar) and the expanded
controls screen (tap the bar) show no movie poster — title and
playback controls work fine, the artwork area is just empty.

### What we know

As of v1.5.0 the app **does** attach the item's primary image to the
cast metadata (`GCKMediaMetadata.addImage`), and that image URL is a
valid, reachable JPEG (verified by hand). Even so, the artwork still
doesn't appear in the iOS cast controls, and we haven't pinned down
why yet. It could be how the image is formatted or sized, how the
metadata is passed along, or how the receiver surfaces sender-provided
images — we genuinely don't know. Other cast apps show artwork fine,
so it's very likely something we're still missing rather than a hard
limitation.

### Status

🐛 **Known, cause not yet understood. Cosmetic only.** Playback, the
quality picker / bitrate, and the expanded time-slider controls all
work normally — only the poster area is blank. No workaround needed.

---

## 🟡 Stopping the cast from the expanded controls leaves the app out of sync

**Affected versions:** v1.3.0.

### Symptom

If you stop casting from the **expanded controls screen** (tap the
mini controller → tap the cast button there → "Stop casting"), the TV
stops correctly, but Swiftfin doesn't register that the session ended:
the next tap on the Cast button jumps straight to the device picker
instead of showing the quality picker first.

Stopping from the **first-level dialog** (tap the Cast button in the
player → "Stop casting") behaves correctly.

### Workaround (empirically verified)

Stop casts from the first-level cast dialog rather than from inside
the expanded controls. If you already hit the bug, force-quitting
Swiftfin restores a clean state on next launch.

### Status

🐛 **Known.** Likely a session-state callback not firing for that
particular teardown path. Under investigation for a patch release.

---


