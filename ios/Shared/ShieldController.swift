import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

extension ManagedSettingsStore.Name {
    static let keyholder = Self("keyholder")
}

extension DeviceActivityName {
    /// Ends when an approved temporary unlock expires: shields come back.
    static let unlockWindow = Self("unlockWindow")
    /// Ends when the Break Glass cooling-off completes: everything is lifted.
    static let breakGlass = Self("breakGlass")
    /// Daily schedule whose callbacks give the extension a chance to send a heartbeat.
    static let heartbeat = Self("heartbeat")
}

/// Thin wrapper over the ManagedSettings store. Used by the app and the monitor extension.
enum ShieldController {
    static let store = ManagedSettingsStore(named: .keyholder)

    static func applyShields(_ selection: FamilyActivitySelection) {
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        // Stops the app being deleted while a block is on. Only honoured while
        // Screen Time authorization stands.
        store.application.denyAppRemoval = true
    }

    /// Temporary unlock: apps open, but the app itself still cannot be deleted.
    static func liftShieldsKeepingRemovalDenied() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.application.denyAppRemoval = true
    }

    static func clearEverything() {
        store.clearAllSettings()
    }

    static var isShielding: Bool {
        if let apps = store.shield.applications, !apps.isEmpty { return true }
        return store.shield.applicationCategories != nil
    }
}

/// Schedules DeviceActivity intervals so the monitor extension fires even when
/// the app is not running. Apple requires intervals of at least 15 minutes.
enum MonitorScheduler {
    static let minimumInterval: TimeInterval = 15 * 60 + 30

    static func schedule(_ name: DeviceActivityName, until end: Date) throws {
        let center = DeviceActivityCenter()
        center.stopMonitoring([name])

        let now = Date()
        let safeEnd = max(end, now.addingTimeInterval(minimumInterval))
        let calendar = Calendar.current
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(components, from: now),
            intervalEnd: calendar.dateComponents(components, from: safeEnd),
            repeats: false
        )
        try center.startMonitoring(name, during: schedule)
    }

    static func cancel(_ names: DeviceActivityName...) {
        DeviceActivityCenter().stopMonitoring(names)
    }

    static func cancelAll() {
        DeviceActivityCenter().stopMonitoring()
    }

    /// A repeating daily interval. intervalDidStart/End give the extension two
    /// chances a day to post a heartbeat without the app being opened.
    static func ensureDailyHeartbeat() {
        let center = DeviceActivityCenter()
        guard !center.activities.contains(.heartbeat) else { return }
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        try? center.startMonitoring(.heartbeat, during: schedule)
    }
}
