//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import JellyfinAPI
import SwiftUI

extension ItemView {

    struct ActionButtonHStack: View {

        @Default(.accentColor)
        private var accentColor

        @StoredValue(.User.enabledTrailers)
        private var enabledTrailers: TrailerSelection

        @ObservedObject
        var viewModel: ItemViewModel

        // Fork addition: observe Cast availability so the Cast button can be
        // shown only when a device is around, and drive discovery from here
        // (this row is always present on the detail page, unlike the button
        // itself which is conditionally mounted).
        @InjectedObject(\.castManager)
        private var castManager: CastManager

        @Environment(\.scenePhase)
        private var scenePhase

        var equalSpacing: Bool = true

        // MARK: - Has Trailers

        private var hasTrailers: Bool {
            if enabledTrailers.contains(.local), viewModel.localTrailers.isNotEmpty {
                return true
            }

            if enabledTrailers.contains(.external), viewModel.item.remoteTrailers?.isNotEmpty == true {
                return true
            }

            return false
        }

        // MARK: - Body

        var body: some View {
            HStack(alignment: .center, spacing: 10) {

                if viewModel.item.canBePlayed {

                    // MARK: - Toggle Played

                    let isCheckmarkSelected = viewModel.item.userData?.isPlayed == true

                    Button(L10n.played, systemImage: "checkmark") {
                        viewModel.send(.toggleIsPlayed)
                    }
                    .buttonStyle(.tintedMaterial(tint: .jellyfinPurple, foregroundColor: .white))
                    .isSelected(isCheckmarkSelected)
                    .frame(maxWidth: .infinity)
                    .if(!equalSpacing) { view in
                        view.aspectRatio(1, contentMode: .fit)
                    }
                }

                // MARK: - Toggle Favorite

                let isHeartSelected = viewModel.item.userData?.isFavorite == true

                Button(L10n.favorite, systemImage: isHeartSelected ? "heart.fill" : "heart") {
                    viewModel.send(.toggleIsFavorite)
                }
                .buttonStyle(.tintedMaterial(tint: .red, foregroundColor: .white))
                .isSelected(isHeartSelected)
                .frame(maxWidth: .infinity)
                .if(!equalSpacing) { view in
                    view.aspectRatio(1, contentMode: .fit)
                }

                // MARK: - Select a Version

                if let mediaSources = viewModel.playButtonItem?.mediaSources,
                   mediaSources.count > 1
                {
                    VersionMenu(
                        viewModel: viewModel,
                        mediaSources: mediaSources
                    )
                    .menuStyle(.button)
                    .frame(maxWidth: .infinity)
                    .if(!equalSpacing) { view in
                        view.aspectRatio(1, contentMode: .fit)
                    }
                }

                // MARK: - Watch a Trailer

                if hasTrailers {
                    TrailerMenu(
                        localTrailers: viewModel.localTrailers,
                        externalTrailers: viewModel.item.remoteTrailers ?? []
                    )
                    .menuStyle(.button)
                    .frame(maxWidth: .infinity)
                    .if(!equalSpacing) { view in
                        view.aspectRatio(1, contentMode: .fit)
                    }
                }

                // MARK: - Cast to Chromecast (fork addition)

                // Only present when a Cast device is available (or a session
                // is active), so the row has no reserved/empty slot otherwise
                // — the button simply appears once discovery finds a device.
                if castManager.hasAvailableDevices || castManager.isSessionActive {
                    CastActionButton(viewModel: viewModel)
                        .frame(maxWidth: .infinity)
                        .if(!equalSpacing) { view in
                            view.aspectRatio(1, contentMode: .fit)
                        }
                }
            }
            .font(.title3)
            .fontWeight(.semibold)
            .buttonStyle(.material)
            .labelStyle(.iconOnly)
            // Kick discovery while the detail page is shown so the Cast button
            // appears without the user first opening Google Home (the button
            // is conditionally mounted, so it can't drive discovery itself).
            .onAppear { castManager.refreshDiscovery() }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active { castManager.refreshDiscovery() }
            }
        }
    }
}
