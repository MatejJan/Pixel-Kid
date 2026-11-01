import AVFoundation
import CoreImage
import UIKit

/// Measurements of the most recent frame, shown over the preview.
struct FrameStats {
    var iso: Float = 0
    var exposureDuration: Double = 0
    var fps: Double = 0
    /// Mean linear luminance of the unprocessed frame (0–1).
    var brightness: Double = 0
    /// Brightness divided by ISO and shutter time, so it measures the light in the
    /// room regardless of camera settings. Only meaningful for comparing readings.
    var lightIndex: Double = 0
}

/// How frames are brightened and cleaned up before display.
struct ProcessingSettings {
    var gainEV: Double = 0
    /// Number of frames in the running average of the live view (1 = off).
    var liveAveraging: Int = 1
    var noiseReduction: Bool = false
}

struct PeekResult: Identifiable {
    let id = UUID()
    let image: UIImage
    let frameCount: Int
    let seconds: Double
    let iso: Float
    let exposureDuration: Double
}

/// State is split between the main thread (published values), sessionQueue (device setup) and videoQueue (frames).
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Position: String, CaseIterable, Identifiable {
        case back, front
        var id: Self { self }
    }

    @Published private(set) var previewImage: CGImage?
    @Published private(set) var stats = FrameStats()
    @Published private(set) var isoRange: ClosedRange<Float> = 25...1600
    @Published private(set) var exposureRange: ClosedRange<Double> = 0.0001...0.5
    @Published private(set) var cameraUnavailable = false
    @Published private(set) var stackProgress: Double?

    @Published var position: Position = .back { didSet { if position != oldValue { configureSession() } } }
    @Published var manualExposure = false { didSet { applyExposure() } }
    @Published var iso: Float = 800 { didSet { applyExposure() } }
    @Published var exposureDuration: Double = 1.0 / 15 { didSet { applyExposure() } }

    @Published var gainEV: Double = 0 { didSet { updateProcessing() } }
    @Published var liveAveraging: Int = 1 { didSet { updateProcessing() } }
    @Published var noiseReduction = false { didSet { updateProcessing() } }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "PixelKid.session")
    private let videoQueue = DispatchQueue(label: "PixelKid.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?

    private let context = CIContext(options: [.cacheIntermediates: false])

    // Owned by videoQueue.
    private var processing = ProcessingSettings()
    private var liveAccumulator: CIImageAccumulator?
    private var lastFrameTime: CMTime?
    private var smoothedFPS: Double = 0
    private var stackJob: StackJob?

    private static let previewWidth: CGFloat = 720

    // MARK: - Lifecycle

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.cameraUnavailable = true }
                return
            }
            self.configureSession()
            self.sessionQueue.async { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
    }

    // MARK: - Configuration

    private func configureSession() {
        let position: AVCaptureDevice.Position = self.position == .back ? .back : .front

        sessionQueue.async { [self] in
            session.beginConfiguration()

            for input in session.inputs { session.removeInput(input) }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.cameraUnavailable = true }
                return
            }
            session.addInput(input)
            self.device = device

            if session.outputs.isEmpty {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            }

            selectLowLightFormat(for: device)

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = position == .front
                }
            }

            session.commitConfiguration()

            let format = device.activeFormat
            let isoRange = format.minISO...format.maxISO
            let exposureRange = format.minExposureDuration.seconds...min(format.maxExposureDuration.seconds, Self.longestFrameDuration(of: format).seconds)

            DispatchQueue.main.async {
                self.cameraUnavailable = false
                self.isoRange = isoRange
                self.exposureRange = exposureRange
                // Clamping triggers applyExposure through didSet.
                self.iso = min(max(self.iso, isoRange.lowerBound), isoRange.upperBound)
                self.exposureDuration = min(max(self.exposureDuration, exposureRange.lowerBound), exposureRange.upperBound)
                self.applyExposure()
            }
        }
    }

    /// Picks the format (up to 1080p) that allows the longest exposures.
    private func selectLowLightFormat(for device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width <= 1920 && dimensions.height <= 1080 && dimensions.width >= 1280
        }

        let best = candidates.max { a, b in
            let aExposure = min(a.maxExposureDuration.seconds, Self.longestFrameDuration(of: a).seconds)
            let bExposure = min(b.maxExposureDuration.seconds, Self.longestFrameDuration(of: b).seconds)
            if aExposure != bExposure { return aExposure < bExposure }
            let aSize = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let bSize = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return aSize.width * aSize.height < bSize.width * bSize.height
        }

        guard let best, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = best
        device.unlockForConfiguration()
    }

    private static func longestFrameDuration(of format: AVCaptureDevice.Format) -> CMTime {
        format.videoSupportedFrameRateRanges.map(\.maxFrameDuration).max() ?? CMTime(value: 1, timescale: 30)
    }

    private static func shortestFrameDuration(of format: AVCaptureDevice.Format) -> CMTime {
        format.videoSupportedFrameRateRanges.map(\.minFrameDuration).min() ?? CMTime(value: 1, timescale: 30)
    }

    private func applyExposure() {
        let manual = manualExposure
        let iso = iso
        let duration = exposureDuration

        sessionQueue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }

            let format = device.activeFormat
            let shortestFrame = Self.shortestFrameDuration(of: format)
            let longestFrame = Self.longestFrameDuration(of: format)

            if manual {
                var exposure = CMTime(seconds: duration, preferredTimescale: 1_000_000)
                exposure = CMTimeMaximum(exposure, format.minExposureDuration)
                exposure = CMTimeMinimum(exposure, CMTimeMinimum(format.maxExposureDuration, longestFrame))

                // The frame must last at least as long as the exposure.
                let frame = CMTimeMaximum(exposure, shortestFrame)
                setFrameDurations(device, min: frame, max: frame)

                let clampedISO = min(max(iso, format.minISO), format.maxISO)
                device.setExposureModeCustom(duration: exposure, iso: clampedISO)
            } else {
                // Let auto exposure slow the frame rate down in the dark.
                setFrameDurations(device, min: shortestFrame, max: longestFrame)
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }

            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = !manual
            }
        }
    }

    /// Sets frame durations in an order that never leaves min above max.
    private func setFrameDurations(_ device: AVCaptureDevice, min: CMTime, max: CMTime) {
        if min > device.activeVideoMaxFrameDuration {
            device.activeVideoMaxFrameDuration = max
            device.activeVideoMinFrameDuration = min
        } else {
            device.activeVideoMinFrameDuration = min
            device.activeVideoMaxFrameDuration = max
        }
    }

    private func updateProcessing() {
        let settings = ProcessingSettings(gainEV: gainEV, liveAveraging: liveAveraging, noiseReduction: noiseReduction)
        videoQueue.async { self.processing = settings }
    }

    // MARK: - Peek

    /// Averages all frames captured over the given time into one still image.
    func captureStack(seconds: Double) async -> PeekResult? {
        await withCheckedContinuation { continuation in
            videoQueue.async {
                self.stackJob = StackJob(seconds: seconds) { result in
                    continuation.resume(returning: result)
                }
            }
            DispatchQueue.main.async { self.stackProgress = 0 }
        }
    }

    private func finishStack(_ job: StackJob) {
        stackJob = nil

        var result: PeekResult?
        if let stacked = job.image {
            let processed = process(stacked, with: processing)
            if let cgImage = context.createCGImage(processed, from: processed.extent) {
                result = PeekResult(
                    image: UIImage(cgImage: cgImage),
                    frameCount: job.frameCount,
                    seconds: job.elapsed,
                    iso: device?.iso ?? 0,
                    exposureDuration: device?.exposureDuration.seconds ?? 0
                )
            }
        }

        DispatchQueue.main.async {
            self.stackProgress = nil
            job.completion(result)
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = CIImage(cvPixelBuffer: pixelBuffer)

        if let job = stackJob {
            job.add(frame, at: time)
            let progress = min(job.elapsed / job.seconds, 1)
            DispatchQueue.main.async { self.stackProgress = progress }
            if job.elapsed >= job.seconds { finishStack(job) }
        }

        var image = frame
        if processing.liveAveraging > 1 {
            if liveAccumulator?.extent != frame.extent {
                liveAccumulator = CIImageAccumulator(extent: frame.extent, format: .RGBAh)
                liveAccumulator?.setImage(frame)
            }
            if let accumulator = liveAccumulator {
                accumulator.setImage(accumulator.image().blended(toward: frame, amount: 1 / Double(processing.liveAveraging)))
                image = accumulator.image()
            }
        } else {
            liveAccumulator = nil
        }

        let scale = Self.previewWidth / image.extent.width
        let preview = process(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), with: processing)
        let cgImage = context.createCGImage(preview, from: preview.extent)

        if let lastFrameTime {
            let delta = (time - lastFrameTime).seconds
            if delta > 0 { smoothedFPS = smoothedFPS == 0 ? 1 / delta : smoothedFPS * 0.8 + (1 / delta) * 0.2 }
        }
        lastFrameTime = time

        var stats = FrameStats()
        stats.iso = device?.iso ?? 0
        stats.exposureDuration = device?.exposureDuration.seconds ?? 0
        stats.fps = smoothedFPS
        stats.brightness = meanLuminance(of: frame)
        if stats.iso > 0, stats.exposureDuration > 0 {
            stats.lightIndex = stats.brightness / (Double(stats.iso) / 100 * stats.exposureDuration) * 100
        }

        DispatchQueue.main.async {
            self.previewImage = cgImage
            self.stats = stats
        }
    }

    private func process(_ image: CIImage, with settings: ProcessingSettings) -> CIImage {
        var result = image
        if settings.gainEV > 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.gainEV])
        }
        if settings.noiseReduction {
            result = result.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.03, "inputSharpness": 0.4])
        }
        return result.cropped(to: image.extent)
    }

    private func meanLuminance(of image: CIImage) -> Double {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        // Rendering without a color space keeps the linear working-space values.
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2])
    }
}

/// Averages frames for a peek. Used only on the video queue.
private final class StackJob {
    let seconds: Double
    let completion: (PeekResult?) -> Void
    private(set) var frameCount = 0
    private var startTime: CMTime?
    private(set) var elapsed: Double = 0
    private var accumulator: CIImageAccumulator?

    init(seconds: Double, completion: @escaping (PeekResult?) -> Void) {
        self.seconds = seconds
        self.completion = completion
    }

    var image: CIImage? { accumulator?.image() }

    func add(_ frame: CIImage, at time: CMTime) {
        if startTime == nil { startTime = time }
        elapsed = (time - startTime!).seconds

        frameCount += 1
        if accumulator == nil {
            accumulator = CIImageAccumulator(extent: frame.extent, format: .RGBAf)
            accumulator?.setImage(frame)
        } else if let accumulator {
            // Running mean: each new frame gets weight 1/n.
            accumulator.setImage(accumulator.image().blended(toward: frame, amount: 1 / Double(frameCount)))
        }
    }
}

private extension CIImage {
    /// Linear mix: self × (1 − amount) + target × amount.
    func blended(toward target: CIImage, amount: Double) -> CIImage {
        applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: target, kCIInputTimeKey: amount])
    }
}
