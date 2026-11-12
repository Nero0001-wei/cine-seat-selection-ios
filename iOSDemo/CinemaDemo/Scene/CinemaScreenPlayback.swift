import AVFoundation
import Foundation
import RealityKit
import UIKit

/// Optional local trailer playback. A missing resource leaves the static screen intact.
/// The owning scene calls stop() when its coordinator is dismantled.
@MainActor
final class CinemaScreenPlayback {
    private let url: URL
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let observations = CinemaPlaybackObservations()
    private var preparationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var onMaterialReady: (@MainActor (VideoMaterial, Float) -> Void)?
    private var onFailure: (@MainActor () -> Void)?
    private var aspectRatio: Float = 16 / 9
    private var wantsPlayback = false
    private var applicationIsActive = false
    private var hasStarted = false
    private var isReady = false
    private var hasFailed = false
    private var isStopped = false

    init?(bundle: Bundle = .main) {
        var foundURL: URL?
        for ext in ["mp4", "mov", "m4v"] {
            foundURL = bundle.url(forResource: "cinema-trailer", withExtension: ext)
                ?? bundle.url(forResource: "cinema-trailer", withExtension: ext, subdirectory: "Media")
            if foundURL != nil { break }
        }
        guard let foundURL,
              let values = try? foundURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        url = foundURL
        player.isMuted = true
        player.volume = 0
    }

    /// Delivers material only after the first queued video item is ready.
    /// Ratio includes the track's display orientation; the scene should aspect-fit it.
    func prepare(onMaterialReady: @escaping @MainActor (VideoMaterial, Float) -> Void,
                 onFailure: @escaping @MainActor () -> Void) {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        self.onMaterialReady = onMaterialReady
        self.onFailure = onFailure
        applicationIsActive = UIApplication.shared.applicationState == .active
        observeApplicationActivity()

        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) }
            catch { return }
            guard let self, !self.isReady, !self.isStopped else { return }
            self.fail()
        }
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: self.url)
                let (playable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
                guard !Task.isCancelled, !self.isStopped else { return }
                guard playable, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
                      let track = tracks.first(where: { $0.mediaType == .video }) else {
                    self.fail()
                    return
                }
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                guard !Task.isCancelled, !self.isStopped else { return }
                let displayBounds = CGRect(origin: .zero, size: size).applying(transform)
                let width = abs(displayBounds.width), height = abs(displayBounds.height)
                guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                    self.fail()
                    return
                }
                self.aspectRatio = Float(width / height)
                // Loading positive duration before constructing AVPlayerLooper avoids
                // its zero-duration precondition and synchronous metadata loading.
                let template = AVPlayerItem(asset: asset)
                self.looper = AVPlayerLooper(player: self.player, templateItem: template)
                self.observePlayer()
            } catch {
                if !Task.isCancelled { self.fail() }
            }
        }
    }

    /// Enable only for an active, unobscured seat preview, not overview/cutaway.
    func setPlaybackEnabled(_ enabled: Bool) {
        guard !isStopped else { return }
        wantsPlayback = enabled
        applyPlaybackState()
    }

    func play() { setPlaybackEnabled(true) }
    func pause() { setPlaybackEnabled(false) }

    /// Terminal cleanup. Make another helper to load a different resource.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        wantsPlayback = false
        preparationTask?.cancel()
        preparationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        observations.removeAll()
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        onMaterialReady = nil
        onFailure = nil
    }

    private func observePlayer() {
        observations.status.append(player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                if self.player.status == .failed { self.fail() }
            }
        })
        observations.status.append(player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeCurrentItem() }
        })
        if let looper {
            observations.status.append(looper.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    if self.looper?.status == .failed { self.fail() }
                }
            })
        }
        observations.notifications.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard let self, !self.isStopped,
                      (item.asset as? AVURLAsset)?.url == self.url else { return }
                self.fail()
            }
        })
    }

    private func observeCurrentItem() {
        guard !isStopped, let item = player.currentItem else { return }
        observations.currentItem?.invalidate()
        observations.currentItem = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.handleCurrentItemStatus() }
        }
    }

    private func handleCurrentItemStatus() {
        guard !isStopped, let item = player.currentItem else { return }
        if item.status == .failed { fail(); return }
        guard item.status == .readyToPlay else { return }
        if !isReady {
            isReady = true
            timeoutTask?.cancel()
            timeoutTask = nil
            let callback = onMaterialReady
            onMaterialReady = nil
            callback?(VideoMaterial(avPlayer: player), aspectRatio)
        }
        applyPlaybackState()
    }

    private func observeApplicationActivity() {
        observations.notifications.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationIsActive = false
                self?.applyPlaybackState()
            }
        })
        observations.notifications.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationIsActive = true
                self?.applyPlaybackState()
            }
        })
    }

    private func applyPlaybackState() {
        if !isStopped, isReady, wantsPlayback, applicationIsActive { player.play() }
        else { player.pause() }
    }

    private func fail() {
        guard !hasFailed, !isStopped else { return }
        hasFailed = true
        let callback = onFailure
        stop()
        callback?()
    }

    deinit {
        preparationTask?.cancel()
        timeoutTask?.cancel()
        let player = player
        let looper = looper
        Task { @MainActor in
            player.pause()
            looper?.disableLooping()
            player.removeAllItems()
        }
    }
}

/// Owns Foundation observer tokens independently of the main-actor controller.
private final class CinemaPlaybackObservations {
    var status: [NSKeyValueObservation] = []
    var currentItem: NSKeyValueObservation?
    var notifications: [NSObjectProtocol] = []

    func removeAll() {
        currentItem?.invalidate()
        currentItem = nil
        status.forEach { $0.invalidate() }
        status.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
    }

    deinit { removeAll() }
}
