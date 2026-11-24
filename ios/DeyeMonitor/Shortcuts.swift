import AppIntents

/// Appears in Shortcuts and Spotlight automatically; Siri understands the English phrases
/// (Siri has no Ukrainian voice), and any phrase can be bound to the Action button.
struct SvitloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PowerStatusIntent(),
            phrases: [
                "Is there power in \(.applicationName)",
                "\(.applicationName) status",
                "Чи є світло в \(.applicationName)",
            ],
            shortTitle: "Чи є світло?",
            systemImageName: "bolt.fill")
    }
}
