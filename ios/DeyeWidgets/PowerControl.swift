import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen control: shows whether there is power and opens the app on tap.
@available(iOS 18.0, *)
struct PowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PowerControl", provider: PowerControlProvider()) { value in
            ControlWidgetButton(action: OpenSvitloIntent()) {
                Label(value.title, systemImage: value.symbol)
                Text(value.subtitle)
            }
        }
        .displayName("Світло")
        .description("Чи є світло і заряд батареї Deye.")
    }
}

@available(iOS 18.0, *)
struct PowerControlValue: Sendable {
    var title: String
    var subtitle: String
    var symbol: String
}

@available(iOS 18.0, *)
struct PowerControlProvider: ControlValueProvider {
    var previewValue: PowerControlValue { PowerControlValue(title: "Світло є", subtitle: "100%", symbol: "bolt.fill") }

    func currentValue() async throws -> PowerControlValue {
        let live = try? await APIClient.shared.fetch().live
        let state = PowerState(live)
        var subtitle = live?.soc.map { "батарея \(Int($0))%" } ?? ""
        if let since = live?.sinceDate, state != .unknown {
            subtitle = "\(Fmt.short(Date.now.timeIntervalSince(since)))" + (subtitle.isEmpty ? "" : " · \(subtitle)")
        }
        return PowerControlValue(title: state.title, subtitle: subtitle, symbol: state.symbol)
    }
}
