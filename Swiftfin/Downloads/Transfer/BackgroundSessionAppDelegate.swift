//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import UIKit

// [Downloads fork]

/// The app delegate, which exists for exactly one reason.
///
/// Swiftfin uses the pure SwiftUI lifecycle and had no `UIApplicationDelegate` at
/// all. Background transfers need one anyway: when a download finishes with the
/// app suspended — or killed — iOS relaunches it and calls
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, and
/// that message has no SwiftUI equivalent.
///
/// Everything it does is delegated to ``BackgroundTransferService``. It is kept
/// in this folder rather than next to `SwiftfinApp` so the base file's entire
/// share of background downloads is the one line that installs it.
@MainActor
final class BackgroundSessionAppDelegate: NSObject, UIApplicationDelegate {

    /// Built here rather than resolved from a container.
    ///
    /// The service is main-actor bound and this is a main-actor context, which
    /// sidesteps constructing it from somewhere that is not. It is published into
    /// the container below, so everything else still reaches it the same way it
    /// reaches the rest of the app's services.
    private let transferService = BackgroundTransferService()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        Container.shared.mediaTransferring.register { [transferService] in transferService }

        // Adopt whatever survived the last run before anything asks for new work.
        transferService.reattach()

        return true
    }

    /// iOS woke the app because a background session has results to report.
    ///
    /// The handler must be called once every event has been delivered — that is
    /// what tells the system the app is finished and can be snapshotted. An app
    /// that never calls it is treated as unresponsive, so it is handed straight
    /// to the service, which calls it from `urlSessionDidFinishEvents`.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundTransferService.sessionIdentifier else {
            completionHandler()
            return
        }

        transferService.backgroundCompletionHandler = completionHandler
    }
}
