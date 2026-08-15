//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension ItemFields {

    /// The minimum cases to use when retrieving an item or items
    /// for basic presentation. Depending on the context, using
    /// more fields and including user data may also be necessary.
    static let MinimumFields: [ItemFields] = [
        .mediaSources,
        .parentID,
        // [Downloads fork] The denominator of the download badge on season and
        // series posters: `childCount` is a season's episodes, `recursiveItemCount`
        // a series' episodes across every season. Both are optional fields that
        // Jellyfin only fills in when asked, and both are a single integer, so the
        // cost of asking everywhere is far less than the cost of a second query.
        .childCount,
        .recursiveItemCount,
    ]
}

extension [ItemFields] {

    static var MinimumFields: Self {
        ItemFields.MinimumFields
    }
}
