import SwiftUI

/// Colour schemes for the floating pill. Each is a set of dark-to-mid tones so white text
/// and the waveform stay readable.
enum PillTheme: String, CaseIterable, Identifiable {
    case graphite, ocean, aurora, sunset, forest, rose

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var colors: [Color] {
        switch self {
        case .graphite: return [Color(hex: 0x141416), Color(hex: 0x2C2C32)]
        case .ocean: return [Color(hex: 0x0B2545), Color(hex: 0x13509A), Color(hex: 0x0E7490)]
        case .aurora: return [Color(hex: 0x2E1065), Color(hex: 0x6D28D9), Color(hex: 0x0F766E)]
        case .sunset: return [Color(hex: 0x7C2D12), Color(hex: 0xBE185D), Color(hex: 0xC2410C)]
        case .forest: return [Color(hex: 0x052E16), Color(hex: 0x166534), Color(hex: 0x0F766E)]
        case .rose: return [Color(hex: 0x4C0519), Color(hex: 0x9D174D), Color(hex: 0x7E22CE)]
        }
    }

    /// The red recording dot disappears on warm themes, so those use white.
    var recordingDot: Color {
        switch self {
        case .sunset, .rose: return .white
        default: return Color(red: 1, green: 0.27, blue: 0.23)
        }
    }

    static var current: PillTheme { PillTheme(rawValue: Prefs.pillTheme) ?? .graphite }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The pill's background. While listening, the gradient slowly turns ("waves"); otherwise it
/// is static and the animation timeline is paused, so an idle pill costs nothing to draw.
struct PillBackground: View {
    let theme: PillTheme
    let idle: Bool
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            let angle = animate ? context.date.timeIntervalSinceReferenceDate * 0.9 : 0.6
            Capsule()
                .fill(LinearGradient(colors: theme.colors,
                                     startPoint: UnitPoint(x: 0.5 - 0.5 * cos(angle), y: 0.5 - 0.5 * sin(angle)),
                                     endPoint: UnitPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))))
                .opacity(idle ? 0.7 : 0.95)
                .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        }
    }
}

/// A row of colour swatches for choosing the pill theme.
struct PillThemePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PillTheme.allCases) { theme in
                Button { selection = theme.rawValue } label: {
                    Capsule()
                        .fill(LinearGradient(colors: theme.colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: 44, height: 22)
                        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: selection == theme.rawValue ? 2.5 : 0))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(theme.name)
            }
        }
    }
}
