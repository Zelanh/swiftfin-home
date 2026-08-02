//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

/// The Downloads section of the iOS Settings form.
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/). Holds the
/// downloads-specific settings state (the Wi-Fi-only toggle) here rather than on
/// the base `SettingsView`, which just renders this view.
struct DownloadsSettingsSection: View {

    @Default(.downloadOverWifiOnly)
    private var downloadOverWifiOnly

    @Router
    private var router

    var body: some View {
        Section {
            ChevronButton(L10n.downloads) {
                router.route(to: .downloadList)
            }

            Toggle(L10n.downloadOverWifiOnly, isOn: $downloadOverWifiOnly)
        }
    }
}
