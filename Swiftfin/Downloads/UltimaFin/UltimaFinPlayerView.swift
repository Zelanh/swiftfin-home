//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// Throwaway diagnostic view on a throwaway branch; strings are deliberately
// raw English so they read the same on screen and in the log file.
// swiftlint:disable hard_coded_display_string

import AVFoundation
import Foundation
import SwiftUI
import SwiftVLC

/// [experiment/swiftvlc-player] Diagnostic offline player on **SwiftVLC**.
///
/// ## What the previous run told us
///
/// The log stopped dead on `stage 2 — VLCInstance(arguments:)` with **no**
/// `❌ VLCInstance failed` line. That matters: a `nil` from `libvlc_new` would
/// have thrown `.instanceCreationFailed` and logged cleanly. So the process
/// died *inside* `libvlc_new()` — it did not fail, it never returned.
///
/// ## The hypothesis this build tests
///
/// SwiftVLC's own docs (VLCInstance.swift:23-28) warn that the first instance
/// does "one-time plugin and decoder setup that can be **expensive on iOS**"
/// and offer `prewarmShared()` precisely to avoid "**blocking the main actor**".
/// Both previous revisions did exactly that: built libVLC synchronously on the
/// main actor. A long enough main-thread stall is killed by the OS, and that
/// looks *identical* in our log to a segfault.
///
/// So this build separates the two, by measurement rather than argument:
///
/// - libVLC is created on a **detached background task**, as documented.
/// - A **heartbeat** on an independent GCD thread writes `alive Ns` to the file.
/// - A **main-actor ticker** increments a counter every 100 ms; the heartbeat
///   prints it. If the main thread is stalled the counter freezes while the
///   heartbeat keeps going.
///
/// Reading the resulting file:
///
/// | Log ends with | Verdict |
/// |---|---|
/// | heartbeats running, `ticks=` frozen, then silence | main-thread stall → OS kill |
/// | heartbeats running, `ticks=` advancing, then silence | genuine crash inside libVLC |
/// | no heartbeats at all after stage 2 | instant crash, whole process gone |
/// | `✅ libVLC 4.x` and it plays | it was only the main-actor block all along |
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
    private var tickTask: Task<Void, Never>?
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
            tickTask?.cancel()
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

        // Proof-of-life for the main actor. If the main thread stalls, this
        // stops advancing while the heartbeat below keeps writing.
        let liveness = LivenessProbe()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                liveness.bumpMain()
            }
        }

        // Independent GCD thread: immune to main-actor and to cooperative-pool
        // starvation, so it keeps reporting even if everything else wedges.
        liveness.startHeartbeat()

        // The expensive one. Per SwiftVLC's own guidance this must not run on
        // the main actor: "one-time plugin and decoder setup that can be
        // expensive on iOS ... instead of blocking the main actor".
        log("▶︎ stage 2 — VLCInstance on a DETACHED task (off the main actor)")
        // Tuple instead of Result: VLCInstance.init uses typed throws
        // (`throws(VLCError)`), but this target compiles as Swift 5, where an
        // untyped `catch` still binds `any Error`. Carrying the message as a
        // String sidesteps that mismatch entirely.
        let creation = Task.detached(priority: .userInitiated) { () -> (instance: VLCInstance?, message: String?) in
            do {
                let instance = try VLCInstance(
                    arguments: VLCInstance.defaultArguments + ["--verbose=2"],
                    applicationName: "Swiftfin UltimaFin",
                    httpUserAgent: "Swiftfin"
                )
                return (instance, nil)
            } catch {
                return (nil, String(describing: error))
            }
        }

        let outcome = await creation.value

        guard let instance = outcome.instance else {
            let message = outcome.message ?? "unknown"
            liveness.stop()
            log("❌ VLCInstance failed: \(message)")
            log("   → libVLC returned nil; it could not initialize in this process.")
            failure = "VLCInstance: \(message)"
            return
        }

        liveness.stop()
        log("✅ libVLC \(instance.version) — ABI \(instance.abiVersion)")
        log("   compiler: \(instance.compiler)")
        log("   → survived libvlc_new off the main actor.")

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

// MARK: - Liveness probe

/// Distinguishes "the main thread stalled and the OS killed us" from "we
/// genuinely crashed", which look identical in a plain staged log.
///
/// `bumpMain()` is called from a main-actor loop; the heartbeat runs on its own
/// GCD thread and prints the counter. A frozen counter beside a live heartbeat
/// means the main actor is wedged.
@available(iOS 18.0, *)
private final class LivenessProbe: @unchecked Sendable {

    private let lock = NSLock()
    private var mainTicks = 0
    private var running = true

    func bumpMain() {
        lock.lock()
        mainTicks += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var snapshot: (running: Bool, ticks: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (running, mainTicks)
    }

    /// Fire-and-forget; ends when `stop()` is called or after a hard cap so a
    /// forgotten probe cannot spin forever.
    func startHeartbeat() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let start = Date()
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let state = snapshot
                let elapsed = Date().timeIntervalSince(start)
                guard state.running, elapsed < 120 else {
                    DiagnosticLogFile.shared.write(
                        String(format: "   .. heartbeat stopped at %.1fs (main ticks=%d)", elapsed, state.ticks)
                    )
                    return
                }
                DiagnosticLogFile.shared.write(
                    String(format: "   .. alive %.1fs - main ticks=%d", elapsed, state.ticks)
                )
            }
        }
    }
}

// MARK: - Crash-surviving log file

/// Appends lines to `Documents/UltimaFin-diagnostics.log` with unbuffered
/// `write(2)` calls, so the trail is on disk even if the process dies on the
/// very next instruction. Documents is user-visible (`UIFileSharingEnabled`),
/// so the file can be read and shared from the Files app without a Mac.
///
/// Written from the main actor *and* the heartbeat thread; each call is one
/// `write` syscall, and interleaving whole lines is acceptable here.
@available(iOS 18.0, *)
private final class DiagnosticLogFile: @unchecked Sendable {

    /// Opened exactly once per process.
    static let shared = DiagnosticLogFile()

    private let handle: FileHandle?
    private let start = Date()

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("UltimaFin-diagnostics.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        guard let handle else { return }
        let stamped = String(format: "[%7.3f] %@\n", Date().timeIntervalSince(start), line)
        guard let data = stamped.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    deinit {
        try? handle?.close()
    }
}

// swiftlint:enable hard_coded_display_string
