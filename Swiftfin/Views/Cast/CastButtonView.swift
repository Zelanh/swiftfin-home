//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import GoogleCast
import SwiftUI

/// A SwiftUI wrapper around `GCKUICastButton`.
///
/// Automatically shows/hides the Cast icon based on device availability,
/// and opens the native Cast device picker on tap.
struct CastButtonView: UIViewRepresentable {

    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = tintColor
        button.triggersDefaultCastDialog = true
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {
        uiView.tintColor = tintColor
    }
}
