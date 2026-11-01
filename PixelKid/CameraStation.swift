import SwiftUI
import UIKit

/// The nursery side: owns the camera and screen light, and serves them to viewers.
@MainActor
final class CameraStation: ObservableObject {
    let camera = CameraController()
    let light = ScreenLight()
    private let server = StreamServer()

    @Published var peekSeconds: Double = 3
    @Published var peekCountdown = 5
    @Published var peekUsesLight = true
    @Published private(set) var countdownRemaining: Int?
    @Published private(set) var isPeeking = false
    /// A peek started on this phone, shown here when done.
    @Published var peekResult: PeekResult?

    @Published private(set) var viewerCount = 0
    @Published var streamFPS: Double = 2 { didSet { updateStreaming() } }

    private var statusTimer: Timer?

    init() {
        server.onMessage = { [weak self] message in self?.handle(message) }
        server.onViewerCountChange = { [weak self] count in
            guard let self else { return }
            viewerCount = count
            updateStreaming()
            sendStatus()
        }
    }

    func start() {
        camera.start()
        server.start()
        // Status doubles as a heartbeat so viewers notice when the camera goes quiet.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendStatus() }
        }
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        server.stop()
        camera.stop()
    }

    private func updateStreaming() {
        let server = server
        camera.setStream(fps: streamFPS, sink: viewerCount > 0 ? { server.broadcastFrame($0) } : nil)
    }

    private func handle(_ message: Message) {
        switch message {
        case .setLightOn(let on):
            Task {
                if on {
                    await light.fadeIn()
                } else if !isPeeking {
                    await light.fadeOut()
                }
                sendStatus()
            }
        case .setLightSettings(let settings):
            light.settings = settings
        case .peek(let seconds, let useLight):
            Task { await peek(seconds: seconds, countdown: 0, useLight: useLight, showResult: false) }
        case .setStreamFPS(let fps):
            streamFPS = min(max(fps, 0.5), 10)
        case .status, .peekInfo:
            break
        }
        sendStatus()
    }

    /// Starts a peek from this phone's own controls.
    func peekFromHere() async {
        await peek(seconds: peekSeconds, countdown: peekCountdown, useLight: peekUsesLight, showResult: true)
    }

    private func peek(seconds: Double, countdown: Int, useLight: Bool, showResult: Bool) async {
        guard !isPeeking else { return }
        isPeeking = true
        defer {
            isPeeking = false
            sendStatus()
        }

        for remaining in stride(from: countdown, to: 0, by: -1) {
            countdownRemaining = remaining
            try? await Task.sleep(for: .seconds(1))
        }
        countdownRemaining = nil

        // Leave the light on afterwards if it was already on.
        let lightWasOn = light.isShown
        if useLight && !lightWasOn {
            await light.fadeIn()
            // Give auto exposure a moment to adjust to the new light.
            if !camera.manualExposure { try? await Task.sleep(for: .seconds(1)) }
        }
        sendStatus()

        let result = await camera.captureStack(seconds: seconds)

        if useLight && !lightWasOn { await light.fadeOut() }

        if let result, let jpeg = result.image.jpegData(compressionQuality: 0.85) {
            server.broadcastPeek(result.info, jpeg: jpeg)
        }

        if showResult {
            UINotificationFeedbackGenerator().notificationOccurred(result == nil ? .error : .success)
            peekResult = result
        }
    }

    private func sendStatus() {
        guard server.hasViewers else { return }
        server.broadcast(.status(CameraStatus(
            stats: camera.stats,
            light: light.settings,
            lightOn: light.isShown,
            isPeeking: isPeeking,
            peekProgress: camera.stackProgress,
            streamFPS: streamFPS
        )))
    }
}
