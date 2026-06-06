//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import GoogleCast
import PreferencesView
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let castOptions = GCKCastOptions(receiverApplicationID: CastManager.jellyfinReceiverAppID)
        castOptions.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(castOptions)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        // GCKConsoleLogger was removed in GoogleCast SDK 4.x.
        // For logging, implement GCKLoggerDelegate on a class and assign it to
        // GCKLogger.sharedInstance().delegate. Skipping here — not required for Chromecast functionality.

        // Kick device discovery at app launch (instead of waiting for the
        // first @InjectedObject lookup on CastManager). On a cold launch the
        // iOS Bonjour/mDNS subsystem can take 10–30 seconds to become
        // responsive — starting discovery as early as possible gives it the
        // most chances to populate before the user reaches the video player
        // and expects the Cast button to appear.
        GCKCastContext.sharedInstance().discoveryManager.startDiscovery()

        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {

        guard UIDevice.isPhone else {
            return .allButUpsideDown
        }

        if let presentedViewController = window?.rootViewController?.presentedViewController,
           let preferencesHostingController = presentedViewController as? UIPreferencesHostingController
        {
            return preferencesHostingController.supportedInterfaceOrientations
        }

        return .portrait
    }
}
