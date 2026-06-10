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

**Affected versions:** v1.0.0, v1.1.0, v1.2.0 (partial). **Fully fixed in:** v1.2.1 (and current `main`).

### Symptom (v1.0.0 / v1.1.0)

You tap the Cast button. The quality picker sheet appears, with one of
the tiers already shown selected (the radio button is on it). You tap
**Start** to confirm.

On the server side, the resulting transcoding bitrate **does not
correspond to the tier you saw selected**. For example, with **1.5 Mbps
visually marked**, the resulting FFmpeg `-b:v` came out at ~12 Mbps —
i.e. a much higher tier than the one shown to the user.

This was verified after exhausting the obvious "stale state" causes:

- Restarted the Jellyfin server
- Force-quit Swiftfin from the iPhone app switcher
- Restarted the Chromecast device
- Re-opened the app, re-opened the picker — visual selection still
  showed 1.5 Mbps as expected

The wrong bitrate kept being sent until a **different tier was actively
selected**.

### Workaround for v1.0.0 / v1.1.0 (reliably repeatable)

When the value you want is already shown as visually selected in the
picker, **do not just tap Start**. Instead:

1. Tap a **different** tier than what's already shown (e.g. tap 3 Mbps
   if 1.5 Mbps is shown)
2. Confirm with **Start** — this Cast session will use that different
   tier
3. (Optional) If you want a different tier than the one you just used,
   open the picker again now, pick what you actually want, and confirm

The key: a value only seems to actually be sent after a tier other than
the one shown at picker-open is *actively selected* at least once.

Re-tapping the already-selected tier does NOT count as an active
selection — you have to tap a *different* one.

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

**Stage 2 — v1.2.1 — transcode bitrate now actually follows the
picker.** Root cause: the `MediaPlayerItem` being cast had already
been built for *local* playback with
`Defaults[.VideoPlayer.Playback.appMaximumBitrate]` baked into its
`TranscodingUrl` by Jellyfin. So even when the Cast picker correctly
sent its value alongside, the receiver was following the URL minted
with the global Settings cap, not ours.

v1.2.1 rebuilds the `MediaPlayerItem` inside `CastManager.load` using
the Cast picker's `PlaybackBitrate` tier and the user's global
`compatibilityMode` setting, then injects the resulting
`MediaSource` (with a fresh `TranscodingUrl` containing *our* cap)
into the `BaseItemDto` sent to the receiver. As a side benefit, every
cast attempt now triggers a fresh `getPostedPlaybackInfo` server-side
and therefore a fresh `PlaySessionID` — see the next entry for what
that resolves.

If you are still on a v1.0.0 / v1.1.0 / v1.2.0 IPA, the workaround
above still applies. Upgrade to v1.2.1 or later to stop needing it.

---

## 🟢 Changing the picker tier between two consecutive casts of the same item may not take effect

**Affected versions:** v1.0.0–v1.2.0. **Fixed in:** v1.2.1 (and current `main`).

### Symptom (v1.0.0–v1.2.0)

You cast a movie at one tier (say 1.5 Mbps). It works. You stop the
cast, then cast the **same movie again** shortly after with a
**different tier** (say 20 Mbps). On the server, the FFmpeg transcode
keeps using a bitrate consistent with the **original** cap (~9 Mbps),
not the new one.

The FFmpeg log file for the second cast shows:

- A high `-start_number` value (e.g. 237) instead of `0`.
- A `-b:v` consistent with the original cap, not the new one.

### Workaround for v1.0.0–v1.2.0 (empirically verified)

- **In Jellyfin, hit "Play from Beginning"** from the item's context
  menu before tapping Cast in Swiftfin. This generates a fresh
  transcode session that respects the current picker tier.

### Status

✅ **Fixed in v1.2.1.** The original symptom was a consequence of how
the original `CastManager` worked rather than any server-side caching:
because the `MediaPlayerItem` was built once for local playback and
then handed to `CastManager.load` as-is, all subsequent cast attempts
of the same item shared the same `TranscodingUrl` (with the same
`PlaySessionID` and the same cap baked in) — the receiver was simply
following that URL.

v1.2.1 rebuilds the `MediaPlayerItem` from scratch inside
`CastManager.load` via `MediaPlayerItem.build`, which calls
`getPostedPlaybackInfo` server-side on every cast. Each call yields a
fresh `PlaySessionID` and a transcoder freshly spun up with the chosen
cap. Re-casting the same item with a different picker tier now works
on the first attempt, with no need for "Play from Beginning" or any
other manual cache-invalidation step.

If you are still on a v1.0.0–v1.2.0 IPA, the workaround above still
applies. Upgrade to v1.2.1 or later to stop needing it.

---


