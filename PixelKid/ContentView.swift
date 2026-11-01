import SwiftUI

enum Role: String {
    case camera, viewer
}

struct ContentView: View {
    @AppStorage("role") private var role: Role?

    var body: some View {
        Group {
            switch role {
            case .camera:
                CameraRoot { role = nil }
            case .viewer:
                ViewerView { role = nil }
            case nil:
                RolePicker(role: $role)
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

private struct CameraRoot: View {
    @StateObject private var station = CameraStation()
    let onChangeRole: () -> Void

    var body: some View {
        CameraView(station: station, onChangeRole: onChangeRole)
            .onAppear { station.start() }
            .onDisappear { station.stop() }
    }
}

private struct RolePicker: View {
    @Binding var role: Role?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pixel Kid")
                .font(.largeTitle.bold())
            Text("What is this phone for?")
                .foregroundStyle(.secondary)

            Button {
                role = .camera
            } label: {
                Label("Camera in the nursery", systemImage: "video")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                role = .viewer
            } label: {
                Label("Viewer", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(32)
    }
}

// MARK: - Shared views

struct StatsOverlay: View {
    let stats: FrameStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ISO \(Int(stats.iso))  ·  \(formatShutter(stats.exposureDuration))  ·  \(stats.fps, specifier: "%.1f") fps")
            Text("Brightness \(stats.brightness * 100, specifier: "%.2f")%  ·  Light index \(stats.lightIndex, specifier: "%.2f")")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}

struct LightControls: View {
    @Binding var settings: LightSettings

    var body: some View {
        Picker("Color", selection: $settings.tint) {
            ForEach(ScreenLight.Tint.allCases) { tint in
                Text(tint.rawValue.capitalized).tag(tint)
            }
        }
        .pickerStyle(.segmented)

        LabeledSlider(title: "Screen", value: $settings.screenBrightness, range: 0...1, label: "\(Int(settings.screenBrightness * 100))%")
        LabeledSlider(title: "Color level", value: $settings.level, range: 0.02...1, label: "\(Int(settings.level * 100))%")
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
