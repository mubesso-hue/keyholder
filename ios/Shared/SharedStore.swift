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
    }
}
