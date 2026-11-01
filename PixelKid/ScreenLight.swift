import SwiftUI
import UIKit

/// Turns the whole screen into a soft, colored light source.
@MainActor
final class ScreenLight: ObservableObject {
    enum Tint: String, CaseIterable, Identifiable {
        case red, amber, warm, white
        var id: Self { self }

        var rgb: (Double, Double, Double) {
            switch self {
            case .red: (1, 0, 0)
            case .amber: (1, 0.45, 0)
            case .warm: (1, 0.75, 0.45)
            case .white: (1, 1, 1)
            }
        }
    }

    @Published var tint: Tint = .amber
    /// System screen brightness while lit (0–1).
    @Published var screenBrightness: Double = 1 { didSet { if isShown { screen?.brightness = CGFloat(screenBrightness) } } }
    /// Multiplies the color, for going dimmer than the lowest screen brightness.
    @Published var level: Double = 1
    @Published var fadeSeconds: Double = 1.5

    @Published private(set) var isShown = false
    @Published private(set) var opacity: Double = 0

    private var savedBrightness: Double?

    var color: Color {
        let (r, g, b) = tint.rgb
        return Color(red: r * level, green: g * level, blue: b * level)
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    func fadeIn() async {
        guard !isShown else { return }
        savedBrightness = screen.map { Double($0.brightness) }
        // The overlay starts black, so raising the brightness first emits no light.
        isShown = true
        screen?.brightness = CGFloat(screenBrightness)
        try? await Task.sleep(for: .milliseconds(50))
        withAnimation(.easeInOut(duration: fadeSeconds)) { opacity = 1 }
        try? await Task.sleep(for: .seconds(fadeSeconds))
    }

    func fadeOut() async {
        guard isShown else { return }
        withAnimation(.easeInOut(duration: fadeSeconds)) { opacity = 0 }
        try? await Task.sleep(for: .seconds(fadeSeconds))
        isShown = false
        if let savedBrightness { screen?.brightness = CGFloat(savedBrightness) }
        savedBrightness = nil
    }
}
