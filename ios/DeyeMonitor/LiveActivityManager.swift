import ActivityKit
import Foundation

/// Keeps one outage Live Activity in sync with the latest data the app fetched.
@MainActor
enum LiveActivityManager {
    /// Launch with `-demoOutage` to preview the Live Activity without a real outage.
    static func demoIfRequested() {
        guard CommandLine.arguments.contains("-demoOutage"), Activity<OutageAttributes>.activities.isEmpty else { return }
        let state = OutageAttributes.ContentState(since: .now.addingTimeInterval(-4980), soc: 64,
                                                  emptyAt: .now.addingTimeInterval(7.5 * 3600), load: 380)
        _ = try? Activity.request(attributes: OutageAttributes(), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    }

    static func sync(with live: Live?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let live, live.error == nil,
              !CommandLine.arguments.contains("-demoOutage") else { return }
        let current = Activity<OutageAttributes>.activities.first

        if live.gridOn == false, !live.isStale {
            let since = live.sinceDate ?? current?.content.state.since ?? .now
            let empty = live.runtimeH.flatMap { $0 > 0 ? Date.now.addingTimeInterval($0 * 3600) : nil }
            let state = OutageAttributes.ContentState(since: since, soc: live.soc, emptyAt: empty, load: live.load)
            let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60))
            if let current {
                Task { await current.update(content) }
            } else {
                _ = try? Activity.request(attributes: OutageAttributes(), content: content, pushType: nil)
            }
        } else if live.gridOn == true, let current {
            var state = current.content.state
            state.restoredAt = live.sinceDate ?? .now
            state.emptyAt = nil
            let final = ActivityContent(state: state, staleDate: nil)
            Task { await current.end(final, dismissalPolicy: .after(.now.addingTimeInterval(20 * 60))) }
        }
    }
}
