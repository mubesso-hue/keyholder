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
    /// While given time lasts on a block of picked apps: counts the minutes
    /// spent in them. Runs to the end of the day, then starts again.
    static let credit = Self("credit")
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

    /// Given time used so far for the block, in seconds, as a running total.
    static func creditUsed(_ seconds: Int) -> Self { Self("credit.used.\(seconds)") }

    /// 1800 for "credit.used.1800".
    var creditUsedSeconds: Int? {
        let prefix = "credit.used."
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

    /// Re-applies the block's shields unless the apps are open for time the
    /// keyholder gave: a running clock, or given time Screen Time is counting.
    @discardableResult
    static func applyStoredShieldsUnlessOpen(now: Date = Date()) -> Bool {
        if let until = SharedStore.unlockUntil, until > now { return false }
        if SharedStore.isOpenForGivenTime { return false }
        return applyStoredShields()
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

    /// Starts a one-off window that ends at `end`. Does nothing if that same
    /// window is already running: iOS reports a restarted window as ended,
    /// which made the extension put the shields back during time the
    /// keyholder had given.
    static func schedule(_ name: DeviceActivityName, until end: Date) throws {
        let center = DeviceActivityCenter()
        if center.activities.contains(name),
           let current = SharedStore.scheduledEnd(for: name),
           abs(current.timeIntervalSince(end)) < 1 {
            return
        }
        // The window is being replaced, not ending: tell the extension first.
        SharedStore.setScheduledEnd(end, for: name)
        if center.activities.contains(name) { center.stopMonitoring([name]) }

        let now = Date()
        let calendar = Calendar.current
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        func window(_ start: Date, _ end: Date) -> DeviceActivitySchedule {
            DeviceActivitySchedule(intervalStart: calendar.dateComponents(components, from: start),
                                   intervalEnd: calendar.dateComponents(components, from: end),
                                   repeats: false)
        }
        // iOS wants windows of at least 15 minutes, but a time balance can be
        // shorter (10 minutes left over from earlier). Start the window in the
        // past so it is long enough and still ends on time. If iOS refuses
        // that, pad the end instead.
        if end.timeIntervalSince(now) < minimumInterval {
            do {
                try center.startMonitoring(name, during: window(end.addingTimeInterval(-minimumInterval), end))
                return
            } catch {
                SharedStore.note("short window refused, padding: \(error)")
            }
        }
        try center.startMonitoring(name, during: window(now, max(end, now.addingTimeInterval(minimumInterval))))
    }

    /// Stops the named activities that are running; others are left alone, so
    /// calling this on every refresh doesn't trigger extension callbacks.
    static func cancel(_ names: DeviceActivityName...) {
        let center = DeviceActivityCenter()
        let running = names.filter { center.activities.contains($0) }
        for name in names { SharedStore.setScheduledEnd(nil, for: name) }
        guard !running.isEmpty else { return }
        center.stopMonitoring(running)
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

    // MARK: Given time on blocks of picked apps

    /// What Screen Time counts against given time: the blocked apps, less the
    /// allowance apps while today's allowance lasts (those are open anyway).
    static func creditSelection() -> FamilyActivitySelection? {
        guard SharedStore.blockMode == .selected, var selection = SharedStore.selection else { return nil }
        if SharedStore.allowanceAvailableToday, let allowance = SharedStore.allowanceSelection {
            selection.applicationTokens.subtract(allowance.applicationTokens)
            selection.categoryTokens.subtract(allowance.categoryTokens)
            selection.webDomainTokens.subtract(allowance.webDomainTokens)
        }
        return AppChangePlan.isEmpty(selection) ? nil : selection
    }

    /// Keeps Screen Time counting while given time is left, and stops when
    /// none is. Restarting loses the minutes since the last mark, so it only
    /// restarts when the time given or the counted apps change. Returns
    /// whether it's counting.
    @discardableResult
    static func ensureCreditCounting() -> Bool {
        guard SharedStore.creditLeftSeconds > 0, let selection = creditSelection() else {
            stopCreditCounting()
            return false
        }
        if DeviceActivityCenter().activities.contains(.credit),
           let end = SharedStore.scheduledEnd(for: .credit), end > Date(),
           SharedStore.creditCountingTotal == SharedStore.creditTotalSeconds,
           let counted = SharedStore.creditCountedSelection, sameApps(counted, selection) {
            return true
        }
        do {
            try startCreditCounting(selection: selection)
            return true
        } catch {
            SharedStore.note("credit counting failed: \(error)")
            stopCreditCounting()
            return false
        }
    }

    /// Counts minutes in `selection` from now to the end of the day, with a
    /// mark every few minutes and one when the given time is used up.
    static func startCreditCounting(selection: FamilyActivitySelection) throws {
        let center = DeviceActivityCenter()
        let base = SharedStore.creditUsedSeconds
        let total = SharedStore.creditTotalSeconds
        guard total > base else { return }

        let now = Date()
        let calendar = Calendar.current
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now.addingTimeInterval(86_400)
        let end = max(endOfDay, now.addingTimeInterval(minimumInterval))

        // A restart is reported as an end: tell the extension first.
        SharedStore.setScheduledEnd(end, for: .credit)
        SharedStore.creditCountingTotal = total
        SharedStore.creditCountedSelection = selection
        if center.activities.contains(.credit) { center.stopMonitoring([.credit]) }

        let minutes = max(1, Int((Double(total - base) / 60).rounded()))
        let step = minutes <= 60 ? 1 : (minutes <= 240 ? 5 : 15)
        func event(after m: Int) -> DeviceActivityEvent {
            DeviceActivityEvent(applications: selection.applicationTokens,
                                categories: selection.categoryTokens,
                                webDomains: selection.webDomainTokens,
                                threshold: DateComponents(minute: m))
        }
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [.creditUsed(total): event(after: minutes)]
        for m in stride(from: step, to: minutes, by: step) {
            events[.creditUsed(base + m * 60)] = event(after: m)
        }
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(components, from: now),
            intervalEnd: calendar.dateComponents(components, from: end),
            repeats: false
        )
        try center.startMonitoring(.credit, during: schedule, events: events)
    }

    static func stopCreditCounting() {
        SharedStore.creditCountingTotal = nil
        SharedStore.creditCountedSelection = nil
        cancel(.credit)
    }

    private static func sameApps(_ a: FamilyActivitySelection, _ b: FamilyActivitySelection) -> Bool {
        a.applicationTokens == b.applicationTokens && a.categoryTokens == b.categoryTokens
            && a.webDomainTokens == b.webDomainTokens
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
