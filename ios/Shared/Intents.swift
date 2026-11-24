import AppIntents
import Foundation

/// One-sentence answer used by Siri, Shortcuts and the Control Center button.
enum StatusPhrase {
    static func make(_ live: Live?) -> String {
        guard let live, live.error == nil else { return "Немає зв'язку з Deye." }
        if live.isStale {
            return "Deye не отримує даних" + (live.updatedDate.map { " з \(Fmt.time($0))" } ?? "")
                + ". Схоже, у квартирі немає світла й інтернету."
        }
        var text = live.gridOn == true ? "Світло є" : "Світла немає"
        if let since = live.sinceDate { text += " вже \(Fmt.duration(Date.now.timeIntervalSince(since)))" }
        if let soc = live.soc {
            text += ". Батарея \(Int(soc))%"
            if let h = live.runtimeH, h > 0 { text += ", вистачить приблизно на \(Fmt.duration(h * 3600))" }
        }
        return text + "."
    }
}

struct PowerStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Чи є світло?"
    static var description = IntentDescription("Чи є світло в квартирі, відколи, і заряд батареї Deye.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let live = try? await APIClient.shared.fetch().live
        let text = StatusPhrase.make(live)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct OpenSvitloIntent: AppIntent {
    static var title: LocalizedStringResource = "Відкрити «Світло»"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
}
