//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import GoogleCast

/// One-time GoogleCast SDK bootstrap for the isolated Chromecast integration.
///
/// Called once from `SwiftfinApp.init()` (iOS only). Upstream used to bootstrap
/// this from an `AppDelegate`; current upstream has no AppDelegate, so we hook
/// the App's `init()` with a single guarded line instead.
enum ChromecastBootstrap {

    static func configure() {

        // Point the sender at the DEFAULT Google media receiver (not the
        // Jellyfin receiver). The v1.3.0 architecture negotiates a full
        // Jellyfin stream URL client-side and hands it straight to CAF
        // `loadMedia`, so the generic receiver is all we need — and it honours
        // the bitrate cap Jellyfin already baked into the stream.
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // Let the phone's physical volume buttons control the TV volume while casting.
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)

        // Tapping the mini controller opens the SDK's default expanded controls
        // (with the scrubber / time slider). Without this the mini controller is
        // inert. This flag lived in the old AppDelegate bootstrap and was lost
        // in the port — restoring it is what makes the time slider open again.
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true

        // Eagerly instantiate the CastManager singleton so device discovery
        // starts at launch. iOS's mDNS/Bonjour stack is lazy on a cold start;
        // warming it here is what makes the Cast affordance appear promptly
        // instead of only after the user opens Google Home.
        _ = Container.shared.castManager()
    }
}
