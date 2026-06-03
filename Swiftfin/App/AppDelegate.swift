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
