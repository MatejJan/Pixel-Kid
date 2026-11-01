import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var light = ScreenLight()

    @State private var peekSeconds: Double = 3
    @State private var peekCountdown = 5
    @State private var peekUsesLight = true
    @State private var countdownRemaining: Int?
    @State private var isPeeking = false
    @State private var peekResult: PeekResult?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                preview
                controls
            }

            if let countdownRemaining {
                Text("\(countdownRemaining)")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.7))
            }

            if light.isShown {
                ZStack {
                    Color.black
                    light.color.opacity(light.opacity)
                }
                .ignoresSafeArea()
                .onTapGesture {
                    if !isPeeking { Task { await light.fadeOut() } }
                }
            }
        }
        .statusBarHidden(light.isShown)
        .persistentSystemOverlays(light.isShown ? .hidden : .automatic)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            camera.stop()
        }
        .sheet(item: $peekResult) { result in
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

            statsOverlay

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

    private var statsOverlay: some View {
        let stats = camera.stats
        return VStack(alignment: .leading, spacing: 2) {
            Text("ISO \(Int(stats.iso))  ·  \(formatShutter(stats.exposureDuration))  ·  \(stats.fps, specifier: "%.1f") fps")
            Text("Brightness \(stats.brightness * 100, specifier: "%.2f")%  ·  Light index \(stats.lightIndex, specifier: "%.2f")")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
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
                Picker("Color", selection: $light.tint) {
                    ForEach(ScreenLight.Tint.allCases) { tint in
                        Text(tint.rawValue.capitalized).tag(tint)
                    }
                }
                .pickerStyle(.segmented)

                LabeledSlider(title: "Screen", value: $light.screenBrightness, range: 0...1, label: "\(Int(light.screenBrightness * 100))%")
                LabeledSlider(title: "Color level", value: $light.level, range: 0.02...1, label: "\(Int(light.level * 100))%")
                LabeledSlider(title: "Fade", value: $light.fadeSeconds, range: 0...5, label: String(format: "%.1f s", light.fadeSeconds))

                Button("Turn light on (tap screen to turn off)") {
                    Task { await light.fadeIn() }
                }
            }

            Section {
                LabeledSlider(title: "Stack", value: $peekSeconds, range: 1...10, label: String(format: "%.0f s", peekSeconds))
                Stepper("Countdown: \(peekCountdown) s", value: $peekCountdown, in: 0...15)
                Toggle("Use screen light", isOn: $peekUsesLight)

                Button {
                    Task { await runPeek() }
                } label: {
                    Text("Peek")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPeeking || camera.cameraUnavailable)
            } header: {
                Text("Peek")
            } footer: {
                Text("Averages every frame captured during the stack time into one still. Keep the phone still while it runs.")
            }
        }
    }

    // MARK: - Peek

    private func runPeek() async {
        isPeeking = true
        defer { isPeeking = false }

        for remaining in stride(from: peekCountdown, to: 0, by: -1) {
            countdownRemaining = remaining
            try? await Task.sleep(for: .seconds(1))
        }
        countdownRemaining = nil

        if peekUsesLight {
            await light.fadeIn()
            // Give auto exposure a moment to adjust to the new light.
            if !camera.manualExposure { try? await Task.sleep(for: .seconds(1)) }
        }

        let result = await camera.captureStack(seconds: peekSeconds)

        if peekUsesLight { await light.fadeOut() }

        UINotificationFeedbackGenerator().notificationOccurred(result == nil ? .error : .success)
        peekResult = result
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(label).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct PeekResultView: View {
    let result: PeekResult
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(uiImage: result.image)
                    .resizable()
                    .scaledToFit()
                Text("\(result.frameCount) frames over \(result.seconds, specifier: "%.1f") s  ·  ISO \(Int(result.iso))  ·  \(formatShutter(result.exposureDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Peek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(saved ? "Saved" : "Save to Photos") {
                        UIImageWriteToSavedPhotosAlbum(result.image, nil, nil, nil)
                        saved = true
                    }
                    .disabled(saved)
                }
            }
        }
    }
}

func formatShutter(_ seconds: Double) -> String {
    guard seconds > 0 else { return "–" }
    if seconds < 0.5 { return "1/\(Int((1 / seconds).rounded())) s" }
    return String(format: "%.1f s", seconds)
}
