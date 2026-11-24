import ActivityKit
import Foundation

/// Live Activity shown on the Lock Screen and in the Dynamic Island while there is no power.
/// Started and updated by the app; times tick by themselves, so no push server is needed.
struct OutageAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var since: Date          // when the power went out
        var soc: Double?         // battery % at the last update
        var emptyAt: Date?       // estimated time the battery reaches the cut-off
        var load: Double?        // apartment load, W
        var restoredAt: Date?    // set on the final update when power is back
    }
}
