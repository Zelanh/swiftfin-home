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

## 🟠 The quality picker sometimes sends a different value than what is visually selected

**Affected versions:** v1.0.0.

### Symptom

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

### Workaround (reliably repeatable)

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

🐛 **Known. Fix pending** until the next iteration.

---


