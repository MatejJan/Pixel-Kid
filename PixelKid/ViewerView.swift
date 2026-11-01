import Combine
import SwiftUI

/// The parent's side: shows the camera's stream and sends it commands.
@MainActor
final class ViewerModel: ObservableObject {
    let client = StreamClient()

    @Published private(set) var connection: StreamClient.State = .searching
    @Published private(set) var frame: UIImage?
    @Published private(set) var lastFrameDate: Date?
    @Published private(set) var status: CameraStatus?
    @Published var peekResult: PeekResult?

    @Published var peekSeconds: Double = 3
    @Published var peekUsesLight = true
    @Published var light = LightSettings(tint: .amber, screenBrightness: 1, level: 1) {
        didSet { if light != oldValue && !isSyncingLight { client.send(.setLightSettings(light)) } }
    }

    /// The light settings are taken from the camera once per connection, then driven from here.
    private var hasSyncedLight = false
    private var isSyncingLight = false
    private var pendingPeekInfo: PeekInfo?
    private var cancellable: AnyCancellable?

    init() {
        client.onMessage = { [weak self] message in self?.handle(message) }
        client.onFrame = { [weak self] data in
            self?.frame = UIImage(data: data)
            self?.lastFrameDate = .now
        }
        client.onPeekImage = { [weak self] data in
            guard let self, let info = pendingPeekInfo, let image = UIImage(data: data) else { return }
            pendingPeekInfo = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            peekResult = PeekResult(image: image, frameCount: info.frameCount, seconds: info.seconds, iso: info.iso, exposureDuration: info.exposureDuration)
        }
        cancellable = client.$state.sink { [weak self] state in
            guard let self else { return }
            connection = state
            if case .connected = state { return }
            hasSyncedLight = false
            status = nil
        }
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    func start() { client.start() }
    func stop() { client.stop() }

    func setLightOn(_ on: Bool) { client.send(.setLightOn(on)) }
    func setStreamFPS(_ fps: Double) { client.send(.setStreamFPS(fps)) }
    func peek() { client.send(.peek(seconds: peekSeconds, useLight: peekUsesLight)) }

    private func handle(_ message: Message) {
        switch message {
        case .status(let status):
            self.status = status
            if !hasSyncedLight {
                isSyncingLight = true
                light = status.light
                isSyncingLight = false
                hasSyncedLight = true
            }
        case .peekInfo(let info):
            pendingPeekInfo = info
        case .setLightOn, .setLightSettings, .peek, .setStreamFPS:
            break
        }
    }
}

struct ViewerView: View {
    @StateObject private var model = ViewerModel()
    let onChangeRole: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stream
            controls
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $model.peekResult) { result in
            PeekResultView(result: result)
        }
    }

    // MARK: - Stream

    private var stream: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let frame = model.frame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                connectionBadge
                if let status = model.status { StatsOverlay(stats: status.stats).padding(-8) }
            }
            .padding(8)

            if let status = model.status, status.isPeeking {
                VStack(spacing: 6) {
                    Text(status.peekProgress == nil ? "Preparing peek…" : "Peeking…")
                        .font(.caption)
                        .foregroundStyle(.white)
                    ProgressView(value: status.peekProgress ?? 0)
                        .tint(.white)
                }
                .padding()
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
    }

    private var connectionBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let (text, color) = badge(at: context.date)
            Label(text, systemImage: "circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .labelStyle(BadgeLabelStyle(color: color))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private func badge(at date: Date) -> (String, Color) {
        switch model.connection {
        case .searching:
            return ("Looking for camera…", .orange)
        case .connecting(let name):
            return ("Connecting to \(name)…", .orange)
        case .connected(let name):
            guard let lastFrameDate = model.lastFrameDate else { return ("\(name) · waiting for video", .orange) }
            let age = date.timeIntervalSince(lastFrameDate)
            let fps = model.status?.streamFPS ?? 1
            if age < max(3, 3 / fps) { return ("\(name) · live", .green) }
            return ("\(name) · no video for \(Int(age)) s", .red)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
            Section("Screen light") {
                Toggle("Light on", isOn: Binding(
                    get: { model.status?.lightOn ?? false },
                    set: { model.setLightOn($0) }
                ))
                LightControls(settings: $model.light)
            }
            .disabled(!model.isConnected)

            Section {
                LabeledSlider(title: "Stack", value: $model.peekSeconds, range: 1...10, label: String(format: "%.0f s", model.peekSeconds))
                Toggle("Use screen light", isOn: $model.peekUsesLight)

                Button {
                    model.peek()
                } label: {
                    Text("Peek")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected || model.status?.isPeeking == true)
            } header: {
                Text("Peek")
            } footer: {
                Text("The camera averages several seconds of frames into one clearer still and sends it here.")
            }

            Section("Stream") {
                Picker("Frame rate", selection: Binding(
                    get: { model.status?.streamFPS ?? 2 },
                    set: { model.setStreamFPS($0) }
                )) {
                    ForEach([1.0, 2, 3, 5], id: \.self) { fps in
                        Text("\(Int(fps)) fps").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.isConnected)
            }

            Section {
                Button("Use this phone as the camera instead", action: onChangeRole)
            }
        }
    }
}

private struct BadgeLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color).imageScale(.small)
            configuration.title
        }
    }
}
