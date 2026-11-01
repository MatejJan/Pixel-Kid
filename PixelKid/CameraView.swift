import SwiftUI

/// The camera phone's screen: live preview, tuning controls, and the light overlays.
struct CameraView: View {
    @ObservedObject var station: CameraStation
    @ObservedObject private var camera: CameraController
    @ObservedObject private var light: ScreenLight
    let onChangeRole: () -> Void

    init(station: CameraStation, onChangeRole: @escaping () -> Void) {
        self.station = station
        _camera = ObservedObject(wrappedValue: station.camera)
        _light = ObservedObject(wrappedValue: station.light)
        self.onChangeRole = onChangeRole
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                preview
                controls
            }

            if let countdownRemaining = station.countdownRemaining {
                Text("\(countdownRemaining)")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.7))
            }

            if light.isAsleep {
                Color.black
                    .ignoresSafeArea()
                    .onTapGesture { light.wake() }
            }

            if light.isShown {
                ZStack {
                    Color.black
                    light.color.opacity(light.opacity)
                }
                .ignoresSafeArea()
                .onTapGesture {
                    if !station.isPeeking { Task { await light.fadeOut() } }
                }
            }
        }
        .statusBarHidden(light.isShown || light.isAsleep)
        .persistentSystemOverlays(light.isShown || light.isAsleep ? .hidden : .automatic)
        .sheet(item: $station.peekResult) { result in
            PeekResultView(result: result)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image = camera.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if camera.cameraUnavailable {
                Text("Camera unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            StatsOverlay(stats: camera.stats)

            if let progress = camera.stackProgress {
                ProgressView(value: progress)
                    .tint(.white)
                    .padding()
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
            Section {
                LabeledContent("Viewers connected", value: "\(station.viewerCount)")
                Button("Sleep screen (tap to wake)") { light.sleep() }
            } header: {
                Text("Camera station")
            } footer: {
                Text("Sleep the screen before leaving the nursery so the phone doesn't light up the room.")
            }

            Section("Camera") {
                Picker("Camera", selection: $camera.position) {
                    Text("Back").tag(CameraController.Position.back)
                    Text("Front").tag(CameraController.Position.front)
                }
                .pickerStyle(.segmented)

                Toggle("Manual exposure", isOn: $camera.manualExposure)

                if camera.manualExposure {
                    LabeledSlider(title: "ISO", value: Binding(
                        get: { Double(camera.iso) },
                        set: { camera.iso = Float($0) }
                    ), range: Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound), label: "\(Int(camera.iso))")

                    LabeledSlider(title: "Shutter", value: Binding(
                        get: { log(camera.exposureDuration) },
                        set: { camera.exposureDuration = exp($0) }
                    ), range: log(camera.exposureRange.lowerBound)...log(camera.exposureRange.upperBound), label: formatShutter(camera.exposureDuration))
                }
            }

            Section("Processing") {
                LabeledSlider(title: "Gain", value: $camera.gainEV, range: 0...5, label: String(format: "+%.1f EV", camera.gainEV))
                Stepper("Live averaging: \(camera.liveAveraging == 1 ? "off" : "\(camera.liveAveraging) frames")", value: $camera.liveAveraging, in: 1...16)
                Toggle("Noise reduction", isOn: $camera.noiseReduction)
            }

            Section("Screen light") {
                LightControls(settings: $light.settings)
                LabeledSlider(title: "Fade", value: $light.fadeSeconds, range: 0...5, label: String(format: "%.1f s", light.fadeSeconds))

                Button("Turn light on (tap screen to turn off)") {
                    Task { await light.fadeIn() }
                }
            }

            Section {
                LabeledSlider(title: "Stack", value: $station.peekSeconds, range: 1...10, label: String(format: "%.0f s", station.peekSeconds))
                Stepper("Countdown: \(station.peekCountdown) s", value: $station.peekCountdown, in: 0...15)
                Toggle("Use screen light", isOn: $station.peekUsesLight)

                Button {
                    Task { await station.peekFromHere() }
                } label: {
                    Text("Peek")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(station.isPeeking || camera.cameraUnavailable)
            } header: {
                Text("Peek")
            } footer: {
                Text("Averages every frame captured during the stack time into one still. Keep the phone still while it runs.")
            }

            Section {
                Button("Use this phone as a viewer instead", action: onChangeRole)
            }
        }
    }
}
