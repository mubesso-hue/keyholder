import Foundation
import FamilyControls

/// App Group storage shared by the app and its extensions. Everything the
/// extensions need to act without the app running lives here.
enum SharedStore {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedConfig.appGroupID) ?? .standard
    }

    private enum Key {
        static let selection = "selection"
        static let holderName = "holderName"
        static let blockID = "blockID"
        static let blockActive = "blockActive"
        static let unlockUntil = "unlockUntil"
        static let breakGlassEndsAt = "breakGlassEndsAt"
        static let deviceID = "deviceID"
        static let deviceSecret = "deviceSecret"
        static let pendingShieldRequestAt = "pendingShieldRequestAt"
        static let lastExtensionEvent = "lastExtensionEvent"
        static let blockMode = "blockMode"
        static let allowedSelection = "allowedSelection"
        static let pendingAppChange = "pendingAppChange"
        static let allowanceMinutes = "allowanceMinutes"
        static let allowanceSelection = "allowanceSelection"
        static let allowanceExhaustedDay = "allowanceExhaustedDay"
        static let allowanceUsedDay = "allowanceUsedDay"
        static let allowanceUsedMinutes = "allowanceUsedMinutes"
    }

    // MARK: Blocked apps

    /// The apps and categories the user chose. Opaque tokens; only valid on this device.
    static var selection: FamilyActivitySelection? {
        get {
            guard let data = defaults.data(forKey: Key.selection) else { return nil }
            return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.selection)
            } else {
                defaults.removeObject(forKey: Key.selection)
            }
        }
    }

    /// How the current or next block shields apps. Defaults to everything-except.
    static var blockMode: BlockMode {
        get { defaults.string(forKey: Key.blockMode).flatMap(BlockMode.init(rawValue:)) ?? .allExcept }
        set { defaults.set(newValue.rawValue, forKey: Key.blockMode) }
    }

    /// The apps that stay open in everything-except mode. Remembered between
    /// locks, so after the first time the essentials are already set up.
    static var allowedSelection: FamilyActivitySelection? {
        get {
            guard let data = defaults.data(forKey: Key.allowedSelection) else { return nil }
            return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.allowedSelection)
            } else {
                defaults.removeObject(forKey: Key.allowedSelection)
            }
        }
    }

    /// The selection that shields the current or next block, for a mode.
    static func selection(for mode: BlockMode) -> FamilyActivitySelection {
        switch mode {
        case .selected: return selection ?? FamilyActivitySelection()
        case .allExcept: return allowedSelection ?? FamilyActivitySelection(includeEntireCategory: true)
        }
    }

    /// An app change sent to the keyholder and not yet answered.
    static var pendingAppChange: PendingAppChange? {
        get {
            guard let data = defaults.data(forKey: Key.pendingAppChange) else { return nil }
            return try? JSONDecoder().decode(PendingAppChange.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.pendingAppChange)
            } else {
                defaults.removeObject(forKey: Key.pendingAppChange)
            }
        }
    }

    // MARK: Daily allowance

    /// Minutes a day the current block allows on `allowanceSelection`. 0 = none.
    static var allowanceMinutes: Int {
        get { defaults.integer(forKey: Key.allowanceMinutes) }
        set { defaults.set(newValue, forKey: Key.allowanceMinutes) }
    }

    /// The apps the allowance covers. Remembered between locks.
    static var allowanceSelection: FamilyActivitySelection? {
        get {
            guard let data = defaults.data(forKey: Key.allowanceSelection) else { return nil }
            return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.allowanceSelection)
            } else {
                defaults.removeObject(forKey: Key.allowanceSelection)
            }
        }
    }

    /// The day ("2026-11-02") the allowance ran out. Tomorrow it's available again.
    static var allowanceExhaustedDay: String? {
        get { defaults.string(forKey: Key.allowanceExhaustedDay) }
        set { defaults.set(newValue, forKey: Key.allowanceExhaustedDay) }
    }

    /// Roughly how much of today's allowance is used, in 5-minute steps.
    static var allowanceUsedToday: Int {
        defaults.string(forKey: Key.allowanceUsedDay) == today ? defaults.integer(forKey: Key.allowanceUsedMinutes) : 0
    }

    static func setAllowanceUsed(_ minutes: Int) {
        defaults.set(today, forKey: Key.allowanceUsedDay)
        defaults.set(minutes, forKey: Key.allowanceUsedMinutes)
    }

    /// True while today's allowance apps may be open.
    static var allowanceAvailableToday: Bool {
        guard allowanceMinutes > 0, allowanceExhaustedDay != today,
              let selection = allowanceSelection, !AppChangePlan.isEmpty(selection) else { return false }
        return true
    }

    static var today: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Block state mirrored from the server

    static var holderName: String? {
        get { defaults.string(forKey: Key.holderName) }
        set { defaults.set(newValue, forKey: Key.holderName) }
    }

    static var blockID: String? {
        get { defaults.string(forKey: Key.blockID) }
        set { defaults.set(newValue, forKey: Key.blockID) }
    }

    static var blockActive: Bool {
        get { defaults.bool(forKey: Key.blockActive) }
        set { defaults.set(newValue, forKey: Key.blockActive) }
    }

    static var unlockUntil: Date? {
        get { defaults.object(forKey: Key.unlockUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.unlockUntil) }
    }

    static var breakGlassEndsAt: Date? {
        get { defaults.object(forKey: Key.breakGlassEndsAt) as? Date }
        set { defaults.set(newValue, forKey: Key.breakGlassEndsAt) }
    }

    // MARK: Device identity for the extensions

    static var deviceID: String? {
        get { defaults.string(forKey: Key.deviceID) }
        set { defaults.set(newValue, forKey: Key.deviceID) }
    }

    /// Secret issued by register_device(). Lets extensions talk to the backend
    /// without a user session. v1 keeps it in the App Group defaults; move to a
    /// shared Keychain item if you ship widely.
    static var deviceSecret: String? {
        get { defaults.string(forKey: Key.deviceSecret) }
        set { defaults.set(newValue, forKey: Key.deviceSecret) }
    }

    // MARK: Shield UI state

    /// When the user tapped "Ask" on the shield. Used to show "Asked" instead of re-sending.
    static var pendingShieldRequestAt: Date? {
        get { defaults.object(forKey: Key.pendingShieldRequestAt) as? Date }
        set { defaults.set(newValue, forKey: Key.pendingShieldRequestAt) }
    }

    /// Debug breadcrumb from the extensions, visible in Settings.
    static var lastExtensionEvent: String? {
        get { defaults.string(forKey: Key.lastExtensionEvent) }
        set { defaults.set(newValue, forKey: Key.lastExtensionEvent) }
    }

    static func note(_ event: String) {
        lastExtensionEvent = "\(ISO8601DateFormatter().string(from: Date())) \(event)"
    }

    static func clearBlockState() {
        blockID = nil
        blockActive = false
        unlockUntil = nil
        breakGlassEndsAt = nil
        pendingShieldRequestAt = nil
        pendingAppChange = nil
        allowanceMinutes = 0
        allowanceExhaustedDay = nil
    }
}
