//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// This is a throwaway diagnostic view on a throwaway branch; its strings are
// deliberately raw English so they read the same on screen and in the log file.
// swiftlint:disable hard_coded_display_string

import AVFoundation
import SwiftUI
import SwiftVLC

/// [experiment/swiftvlc-player] Diagnostic offline player on **SwiftVLC**.
///
/// The previous revision crashed instantly on tapping Play, and `try?` did
/// nothing because the crash sites in this path are **not** catchable:
///
/// - `VLCInstance.shared` → `private convenience init()` → `try! self.init(…)`
///   (VLCInstance.swift:265) — fatal if `libvlc_new` returns nil.
/// - `Player.init` → `makeNativePlayer` → `preconditionFailure(…)`
///   (Player.swift:599) — fatal if `libvlc_media_player_new` returns nil.
///
/// Worse, `@State private var player = Player()` ran at *struct init*, i.e.
/// before the view ever appeared — so we were very likely dying while
/// initializing libVLC, not while playing.
///
/// This version therefore:
///  1. never touches `VLCInstance.shared` (uses the throwing `init` instead,
///     so `.instanceCreationFailed` becomes a message rather than a crash),
///  2. builds everything lazily in stages, logging **before** each one,
///  3. pumps libVLC's own log (`--verbose=2`) to screen, and
///  4. mirrors every line to `Documents/UltimaFin-diagnostics.log` with
///     unbuffered writes, so the trail survives a hard crash and can be read
///     from the Files app.
///
/// The last `▶︎ stage` line in that file is where it died.
@available(iOS 18.0, *)
struct UltimaFinPlayerView: View {

    @Router
    private var router

    let url: URL
    let title: String

    @State
    private var player: Player?
    @State
    private var lines: [String] = []
    @State
    private var failure: String?
    @State
    private var logTask: Task<Void, Never>?
    @State
    private var didBoot = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let player {
                VideoView(player)
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Button {
                        router.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2.weight(.semibold))
                    }

                    Text(title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    if let player {
                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                    }

                    Text(verbatim: "SwiftVLC")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.purple, in: Capsule())
                }

                if let failure {
                    Text("❌ \(failure)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Rolling libVLC / stage log. Newest at the bottom.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: lines.count) { _, count in
                        guard count > 0 else { return }
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
                .background(.black.opacity(0.55))

                Text("Full log: Files → On My iPhone → Swiftfin → UltimaFin-diagnostics.log")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            await boot()
        }
        .onDisappear {
            logTask?.cancel()
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[error]") || line.hasPrefix("❌") {
            .red
        } else if line.contains("[warning]") {
            .yellow
        } else if line.hasPrefix("▶︎") || line.hasPrefix("✅") {
            .green
        } else {
            .white.opacity(0.7)
        }
    }

    // MARK: - Staged boot

    @MainActor
    private func boot() async {
        guard !didBoot else { return }
        didBoot = true

        log("=====================================================")
        log("▶︎ stage 0 — diagnostics start \(Date().formatted(date: .abbreviated, time: .standard))")
        log("   file: \(url.lastPathComponent)")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        log("   exists: \(FileManager.default.fileExists(atPath: url.path)), size: \(size)")

        log("▶︎ stage 1 — AVAudioSession")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            log("✅ audio session active")
        } catch {
            // Non-fatal for the experiment: we care whether libVLC starts.
            log("   ⚠️ \(String(describing: error))")
        }

        // The interesting one. `VLCInstance.shared` would `try!` here; the
        // throwing initializer lets `.instanceCreationFailed` be reported.
        log("▶︎ stage 2 — VLCInstance(arguments:) [NOT .shared]")
        let instance: VLCInstance
        do {
            instance = try VLCInstance(
                arguments: VLCInstance.defaultArguments + ["--verbose=2"],
                applicationName: "Swiftfin UltimaFin",
                httpUserAgent: "Swiftfin"
            )
        } catch {
            let message = String(describing: error)
            log("❌ VLCInstance failed: \(message)")
            log("   → libVLC could not initialize at all in this process.")
            failure = "VLCInstance: \(message)"
            return
        }
        log("✅ libVLC \(instance.version) — ABI \(instance.abiVersion)")
        log("   compiler: \(instance.compiler)")

        // Subscribe before the player exists so module loading is captured.
        log("▶︎ stage 3 — attaching libVLC log stream")
        let stream = instance.logStream(minimumLevel: .debug)
        logTask = Task { @MainActor in
            for await entry in stream {
                log("[\(entry.level)] \(entry.module ?? "-"): \(entry.message)", toScreen: entry.level >= .notice)
            }
        }
        log("✅ log stream attached")

        // Uncatchable if libvlc_media_player_new returns nil — but the line
        // above is already on disk, so a crash here still tells us where.
        log("▶︎ stage 4 — Player(instance:)  [preconditionFailure if it fails]")
        let newPlayer = Player(instance: instance)
        player = newPlayer
        log("✅ player created")

        // Let SwiftUI actually mount `VideoView` (and hand libVLC its drawable)
        // before playback starts, rather than racing it.
        try? await Task.sleep(for: .milliseconds(150))

        log("▶︎ stage 5 — play(url:)")
        do {
            try newPlayer.play(url: url)
            log("✅ play(url:) returned without throwing")
        } catch {
            let message = String(describing: error)
            log("❌ play failed: \(message)")
            failure = "play: \(message)"
        }

        log("▶︎ stage 6 — running; watching libVLC log")
    }

    // MARK: - Logging

    @MainActor
    private func log(_ message: String, toScreen: Bool = true) {
        // Must NOT be a `@State` instance: a `@State` initializer expression is
        // re-evaluated on every struct re-init, which would re-create (and so
        // truncate) the file on each re-render and destroy the very trail we
        // are trying to capture. One process-wide handle, opened once.
        DiagnosticLogFile.shared.write(message)
        guard toScreen else { return }
        lines.append(message)
        // Keep the on-screen buffer bounded; the file keeps everything.
        if lines.count > 400 {
            lines.removeFirst(lines.count - 400)
        }
    }
}

// MARK: - Crash-surviving log file

/// Appends lines to `Documents/UltimaFin-diagnostics.log` with unbuffered
/// `write(2)` calls, so the trail is on disk even if the process dies on the
/// very next instruction. Documents is user-visible, so the file can be read
/// and shared from the Files app without a Mac.
@available(iOS 18.0, *)
private final class DiagnosticLogFile {

    /// Opened exactly once per process. All writes come from `@MainActor`.
    static let shared = DiagnosticLogFile()

    private let handle: FileHandle?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("UltimaFin-diagnostics.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    deinit {
        try? handle?.close()
    }
}

// swiftlint:enable hard_coded_display_string
