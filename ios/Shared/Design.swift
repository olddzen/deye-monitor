import SwiftUI

/// Visual language: calm surfaces, one state-driven accent, Liquid Glass on iOS 26+, big rounded numerals.
enum PowerState {
    case on, off, unknown

    init(_ live: Live?) {
        guard let live, live.error == nil, !live.isStale else { self = .unknown; return }
        self = live.gridOn == true ? .on : .off
    }

    var accent: Color {
        switch self {
        case .on: return Color(light: 0x0e9f4f, dark: 0x34d27b)
        case .off: return Color(light: 0xe0483b, dark: 0xff6a5c)
        case .unknown: return Color(light: 0xd98a00, dark: 0xffb340)
        }
    }

    var title: String {
        switch self {
        case .on: return "Світло є"
        case .off: return "Світла немає"
        case .unknown: return "Немає даних"
        }
    }

    var symbol: String {
        switch self {
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        case .unknown: return "wifi.exclamationmark"
        }
    }
}

extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Background

struct AmbientBackground: View {
    let state: PowerState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let base = scheme == .dark ? Color(hex: 0x0b0c0d) : Color(hex: 0xf5f5f2)
        ZStack {
            base
            if #available(iOS 18.0, watchOS 11.0, macOS 15.0, *) {
                MeshGradient(
                    width: 3, height: 3,
                    points: [[0, 0], [0.5, 0], [1, 0], [0, 0.45], [0.6, 0.35], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                    colors: [
                        state.accent.opacity(scheme == .dark ? 0.45 : 0.30), state.accent.opacity(0.12), base,
                        state.accent.opacity(0.10), base, base,
                        base, base, base,
                    ])
            } else {
                LinearGradient(colors: [state.accent.opacity(0.25), base], startPoint: .topLeading, endPoint: .center)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: state.title)
    }
}

// MARK: - Glass surfaces

struct GlassCard: ViewModifier {
    var radius: CGFloat = 28
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let inner = content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        if #available(iOS 26.0, watchOS 26.0, macOS 26.0, *) {
            inner.glassEffect(.regular, in: shape)
        } else {
            inner.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension View {
    func glassCard(radius: CGFloat = 28, padding: CGFloat = 18) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Number + unit, unit set smaller and lighter.
struct Metric: View {
    let value: String
    let unit: String
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.display(size)).monospacedDigit().contentTransition(.numericText())
            Text(unit).font(.display(size * 0.5, .medium)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Thin horizontal capsule meter (battery, shares).
struct CapsuleMeter: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.6), value: fraction)
    }
}
