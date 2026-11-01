import Foundation
import Network
import UIKit

// MARK: - Protocol

/// Bonjour service the camera advertises and viewers browse for.
let pixelKidServiceType = "_pixelkid._tcp"

/// Packets are framed as [kind: UInt8][length: UInt32 big endian][payload].
enum PacketKind: UInt8 {
    /// A JSON-encoded `Message`.
    case message = 1
    /// A JPEG of the live view.
    case frame = 2
    /// A full-resolution JPEG of a finished peek, preceded by a `.peekInfo` message.
    case peekImage = 3
}

enum Message: Codable {
    // Camera → viewer
    case status(CameraStatus)
    case peekInfo(PeekInfo)

    // Viewer → camera
    case setLightOn(Bool)
    case setLightSettings(LightSettings)
    case peek(seconds: Double, useLight: Bool)
    case setStreamFPS(Double)
}

struct LightSettings: Codable, Equatable {
    var tint: ScreenLight.Tint
    var screenBrightness: Double
    var level: Double
}

struct CameraStatus: Codable {
    var stats: FrameStats
    var light: LightSettings
    var lightOn: Bool
    var isPeeking: Bool
    var peekProgress: Double?
    var streamFPS: Double
}

struct PeekInfo: Codable {
    var frameCount: Int
    var seconds: Double
    var iso: Float
    var exposureDuration: Double
}

// MARK: - Connection

/// One TCP connection that sends and receives framed packets. Handlers are called on the main queue.
final class PeerConnection: @unchecked Sendable {
    let connection: NWConnection
    var onPacket: ((PacketKind, Data) -> Void)?
    var onClose: (() -> Void)?

    private let queue: DispatchQueue
    /// Frames queued but not yet handed to the network, used to drop frames when the link is slow.
    private var framesInFlight = 0
    private var closed = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    var name: String {
        if case let .service(name, _, _, _) = connection.endpoint { return name }
        return "\(connection.endpoint)"
    }

    func start(onReady: (() -> Void)? = nil) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let onReady { DispatchQueue.main.async(execute: onReady) }
            case .failed, .cancelled:
                self?.close()
            case .waiting:
                // The other side is unreachable; give up so the caller can retry.
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            connection.cancel()
            DispatchQueue.main.async { self.onClose?() }
        }
    }

    func send(_ message: Message) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        send(.message, data)
    }

    /// Sends a live frame unless the previous one is still on its way.
    func sendFrame(_ data: Data) {
        queue.async { [self] in
            guard framesInFlight == 0 else { return }
            framesInFlight += 1
            send(.frame, data) { self.framesInFlight -= 1 }
        }
    }

    func send(_ kind: PacketKind, _ payload: Data, completion: (() -> Void)? = nil) {
        var packet = Data([kind.rawValue])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            completion?()
            if error != nil { self?.close() }
        })
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == 5, error == nil else {
                if isComplete || error != nil { close() }
                return
            }
            let kindValue = data[data.startIndex]
            let length = data.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            receivePayload(kind: PacketKind(rawValue: kindValue), length: length)
        }
    }

    private func receivePayload(kind: PacketKind?, length: Int) {
        guard length > 0 else {
            receiveHeader()
            return
        }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else {
                close()
                return
            }
            if let kind {
                DispatchQueue.main.async { self.onPacket?(kind, data) }
            }
            receiveHeader()
        }
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Notice a vanished peer within a few seconds instead of minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        tcp.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

// MARK: - Camera side

/// Advertises the camera on the local network and keeps track of connected viewers.
final class StreamServer: @unchecked Sendable {
    var onMessage: ((Message) -> Void)?
    var onViewerCountChange: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "PixelKid.server")
    private var listener: NWListener?
    // Accessed on the main queue.
    private var viewers: [PeerConnection] = []

    func start() {
        guard listener == nil, let listener = try? NWListener(using: PeerConnection.parameters()) else { return }
        listener.service = NWListener.Service(name: UIDevice.current.name, type: pixelKidServiceType)
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                // Typically after the app was suspended; recreate the listener.
                DispatchQueue.main.async {
                    self?.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.start() }
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        viewers.forEach { $0.close() }
    }

    private func accept(_ connection: NWConnection) {
        let viewer = PeerConnection(connection, queue: queue)
        viewer.onPacket = { [weak self] kind, data in
            guard kind == .message, let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
            self?.onMessage?(message)
        }
        viewer.onClose = { [weak self, weak viewer] in
            guard let self else { return }
            viewers.removeAll { $0 === viewer }
            onViewerCountChange?(viewers.count)
        }
        viewers.append(viewer)
        viewer.start()
        onViewerCountChange?(viewers.count)
    }

    var hasViewers: Bool { !viewers.isEmpty }

    func broadcast(_ message: Message) {
        viewers.forEach { $0.send(message) }
    }

    func broadcastPeek(_ info: PeekInfo, jpeg: Data) {
        for viewer in viewers {
            viewer.send(.peekInfo(info))
            viewer.send(.peekImage, jpeg)
        }
    }

    /// Safe to call from any queue.
    func broadcastFrame(_ jpeg: Data) {
        DispatchQueue.main.async { [self] in
            viewers.forEach { $0.sendFrame(jpeg) }
        }
    }
}

// MARK: - Viewer side

/// Finds a camera on the local network and stays connected to it, reconnecting when the link drops.
@MainActor
final class StreamClient: ObservableObject {
    enum State: Equatable {
        case searching
        case connecting(String)
        case connected(String)
    }

    @Published private(set) var state: State = .searching

    var onMessage: ((Message) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onPeekImage: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "PixelKid.client")
    private var browser: NWBrowser?
    private var results: [NWBrowser.Result] = []
    private var peer: PeerConnection?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: pixelKidServiceType, domain: nil), using: PeerConnection.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.results = Array(results)
                self?.connectIfNeeded()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.browser?.cancel()
                    self?.browser = nil
                    try? await Task.sleep(for: .seconds(1))
                    self?.start()
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peer?.onClose = nil
        peer?.close()
        peer = nil
        state = .searching
    }

    func send(_ message: Message) {
        guard case .connected = state else { return }
        peer?.send(message)
    }

    private func connectIfNeeded() {
        guard peer == nil, let result = results.first else { return }

        var name = "camera"
        if case let .service(serviceName, _, _, _) = result.endpoint { name = serviceName }

        let peer = PeerConnection(NWConnection(to: result.endpoint, using: PeerConnection.parameters()), queue: queue)
        peer.onPacket = { [weak self] kind, data in
            guard let self else { return }
            switch kind {
            case .message:
                if let message = try? JSONDecoder().decode(Message.self, from: data) { onMessage?(message) }
            case .frame:
                onFrame?(data)
            case .peekImage:
                onPeekImage?(data)
            }
        }
        peer.onClose = { [weak self] in
            guard let self else { return }
            self.peer = nil
            state = .searching
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.connectIfNeeded()
            }
        }
        self.peer = peer
        state = .connecting(name)
        peer.start { [weak self] in
            Task { @MainActor in self?.state = .connected(name) }
        }
    }
}
