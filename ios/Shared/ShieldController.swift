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
    /// Daily, midnight to midnight: counts the minutes used on allowance apps.
    static let allowance = Self("allowance")
    /// Today only, after the allowance changed mid-day: caps today at what's left.
    static let allowanceToday = Self("allowanceToday")
    /// Daily schedule whose callbacks give the extension a chance to send a heartbeat.
    static let heartbeat = Self("heartbeat")
}

extension DeviceActivityEvent.Name {
    /// Today's allowance is used up.
    static let allowanceDone = Self("allowance.done")
    /// Progress marks every 5 minutes, so the app can show roughly what's left.
    static func allowanceUsed(_ minutes: Int) -> Self { Self("allowance.used.\(minutes)") }

    /// 15 for "allowance.used.15".
    var allowanceUsedMinutes: Int? {
        let prefix = "allowance.used."
        guard rawValue.hasPrefix(prefix) else { return nil }
        return Int(rawValue.dropFirst(prefix.count))
    }
}

/// How a block decides what to shield.
enum BlockMode: String, Codable {
    /// Block only the apps and categories the user picked.
    case selected
    /// Block everything except the apps the user keeps open (Phone, Messages,
    /// Maps, banking...). Apps installed later are blocked too.
    case allExcept = "all_except"
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

    /// Everything is shielded except the allowed apps. Keyholder itself is never
    /// shielded: apps cannot shield themselves through their own store.
    static func applyShields(allowing allowed: FamilyActivitySelection) {
        store.shield.applications = nil
        store.shield.applicationCategories = .all(except: allowed.applicationTokens)
        store.application.denyAppRemoval = true
    }

    /// Re-applies whatever the user chose at Lock time, from the App Group.
    /// Used by the app and by the monitor extension when an unlock window ends
    /// or the daily allowance runs out or starts again.
    ///
    /// While today's allowance lasts, its apps stay open; the monitor extension
    /// shields them once Screen Time counts the minutes.
    @discardableResult
    static func applyStoredShields() -> Bool {
        let allowance = SharedStore.allowanceAvailableToday ? SharedStore.allowanceSelection : nil
        switch SharedStore.blockMode {
        case .allExcept:
            var open = (SharedStore.allowedSelection ?? FamilyActivitySelection()).applicationTokens
            if let allowance { open.formUnion(allowance.applicationTokens) }
            store.shield.applications = nil
            store.shield.applicationCategories = .all(except: open)
            store.application.denyAppRemoval = true
            return true
        case .selected:
            guard let selection = SharedStore.selection else { return false }
            guard let allowance else {
                applyShields(selection)
                return true
            }
            let apps = selection.applicationTokens.subtracting(allowance.applicationTokens)
            let categories = selection.categoryTokens.subtracting(allowance.categoryTokens)
            store.shield.applications = apps.isEmpty ? nil : apps
            store.shield.applicationCategories = categories.isEmpty
                ? nil
                : .specific(categories, except: allowance.applicationTokens)
            store.application.denyAppRemoval = true
            return true
        }
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

    /// Counts minutes on the allowance apps, every day from midnight. Restarting
    /// resets today's count, so callers only start it when it isn't running.
    static func startAllowance(minutes: Int, selection: FamilyActivitySelection) throws {
        let center = DeviceActivityCenter()
        center.stopMonitoring([.allowance])
        guard minutes > 0, !AppChangePlan.isEmpty(selection) else { return }

        func event(after m: Int) -> DeviceActivityEvent {
            DeviceActivityEvent(applications: selection.applicationTokens,
                                categories: selection.categoryTokens,
                                webDomains: selection.webDomainTokens,
                                threshold: DateComponents(minute: m))
        }
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [.allowanceDone: event(after: minutes)]
        for m in stride(from: 5, to: minutes, by: 5) {
            events[.allowanceUsed(m)] = event(after: m)
        }
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        try center.startMonitoring(.allowance, during: schedule, events: events)
    }

    /// Changes the allowance's size or apps mid-day without forgetting what's
    /// already used today. Restarting the daily count would start from zero, so
    /// a separate today-only count caps today at what's left.
    static func restartAllowance(minutes: Int, selection: FamilyActivitySelection) {
        let usedToday = SharedStore.allowanceUsedToday
        SharedStore.allowanceMinutes = minutes
        SharedStore.allowanceSelection = selection
        cancel(.allowance, .allowanceToday)
        guard minutes > 0, !AppChangePlan.isEmpty(selection) else { return }

        try? startAllowance(minutes: minutes, selection: selection)
        let remaining = minutes - usedToday
        if remaining <= 0 {
            SharedStore.allowanceExhaustedDay = SharedStore.today
            return
        }
        if SharedStore.allowanceExhaustedDay == SharedStore.today {
            SharedStore.allowanceExhaustedDay = nil
        }
        guard usedToday > 0 else { return }

        // Today's cap: what's left, counted from now until midnight.
        let calendar = Calendar.current
        let now = Date()
        guard let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now),
              endOfDay.timeIntervalSince(now) >= minimumInterval else { return }
        func event(after m: Int) -> DeviceActivityEvent {
            DeviceActivityEvent(applications: selection.applicationTokens,
                                categories: selection.categoryTokens,
                                webDomains: selection.webDomainTokens,
                                threshold: DateComponents(minute: m))
        }
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [.allowanceDone: event(after: remaining)]
        for m in stride(from: 5, to: remaining, by: 5) {
            events[.allowanceUsed(usedToday + m)] = event(after: m)
        }
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(components, from: now),
            intervalEnd: calendar.dateComponents(components, from: endOfDay),
            repeats: false
        )
        try? DeviceActivityCenter().startMonitoring(.allowanceToday, during: schedule, events: events)
    }

    /// Starts allowance counting if the block has one and it isn't running yet.
    static func ensureAllowance() {
        guard SharedStore.allowanceMinutes > 0, let selection = SharedStore.allowanceSelection,
              !AppChangePlan.isEmpty(selection) else {
            cancel(.allowance, .allowanceToday)
            return
        }
        guard !DeviceActivityCenter().activities.contains(.allowance) else { return }
        try? startAllowance(minutes: SharedStore.allowanceMinutes, selection: selection)
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
