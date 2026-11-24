import SwiftUI
import UIKit

/// Same palette as the web dashboard (validated data-viz palette + reserved status colours).
enum Theme {
    static let series = Color(light: 0x2a78d6, dark: 0x3987e5)
    static let good = Color(hex: 0x0ca30c)
    static let warning = Color(hex: 0xfab219)
    static let critical = Color(hex: 0xd03b3b)
    static let track = Color(light: 0xecebe7, dark: 0x2c2c2a)
    static let noData = Color(light: 0xe3e2dd, dark: 0x2a2a28)
    static let card = Color(light: 0xffffff, dark: 0x1a1a19)
    static let page = Color(light: 0xf4f4f2, dark: 0x111110)
    static let tile = Color(light: 0xfcfcfb, dark: 0x1f1f1e)
    static let line = Color(light: 0xe6e5e0, dark: 0x2c2c2a)
    /// sequential blue, near-zero → max
    static let seq: [Color] = [
        Color(light: 0xcde2fb, dark: 0x104281), Color(light: 0x9ec5f4, dark: 0x184f95),
        Color(light: 0x6da7ec, dark: 0x1c5cab), Color(light: 0x3987e5, dark: 0x256abf),
        Color(light: 0x256abf, dark: 0x3987e5), Color(light: 0x184f95, dark: 0x6da7ec),
        Color(light: 0x0d366b, dark: 0x9ec5f4),
    ]

    static func batteryColor(_ soc: Double?) -> Color {
        guard let soc else { return noData }
        return soc < 20 ? critical : soc < 40 ? warning : good
    }

    static func seqColor(_ share: Double) -> Color {
        guard share > 0 else { return noData }
        return seq[min(seq.count - 1, Int(share * Double(seq.count)))]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }
}
