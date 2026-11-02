import Foundation

// Decoded with .convertFromSnakeCase and SupabaseDates.decode (see SupabaseService).

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    /// Your nickname for this person if you set one, otherwise their own name.
    var displayName: String
    /// Their own name, when it differs from what you see (snapshot profiles only).
    var realName: String?

    var hasNickname: Bool { realName != nil && realName != displayName }
}

enum KeyStatus: String, Codable { case active, ended }

struct Key: Codable, Identifiable, Equatable {
    let id: UUID
    let holderId: UUID
    let lockedId: UUID
    let status: KeyStatus
    let createdAt: Date
    let endedAt: Date?
    let endedReason: String?
}

enum BlockStatus: String, Codable { case active, ended }

enum BlockEndReason: String, Codable {
    case holderEnded = "holder_ended"
    case breakGlass = "break_glass"
    case revoked
    case orphaned
}

struct Block: Codable, Identifiable, Equatable {
    let id: UUID
    let userId: UUID
    let keyId: UUID
    let status: BlockStatus
    let coolingOffHours: Int
    let appCount: Int
    let categoryCount: Int
    let startedAt: Date
    let endedAt: Date?
    let endedReason: BlockEndReason?
    let unlockUntil: Date?
    let breakGlassStartedAt: Date?
    let breakGlassEndsAt: Date?
    let lastHeartbeatAt: Date
    let verified: Bool
    /// "selected" or "all_except". Optional so rows from before the column existed decode.
    let mode: String?
    let allowedCount: Int?
    /// Minutes a day on chosen apps before they block. Optional for older rows.
    let allowanceMinutes: Int?
    /// When the allowance was last changed, by either side.
    let allowanceSetAt: Date?

    var isActive: Bool { status == .active }

    var isAllExcept: Bool { mode == BlockMode.allExcept.rawValue }

    /// "Everything except 6 apps · 30 min a day allowed" or "5 apps, 1 category".
    var summary: String {
        var text: String
        if isAllExcept {
            let n = allowedCount ?? 0
            text = "Everything except \(n) \(n == 1 ? "app" : "apps")"
        } else {
            text = "\(appCount) \(appCount == 1 ? "app" : "apps"), \(categoryCount) \(categoryCount == 1 ? "category" : "categories")"
        }
        if let m = allowanceMinutes, m > 0 {
            text += " · \(UnlockDuration.format(minutes: m)) a day allowed"
        }
        return text
    }

    func isTemporarilyUnlocked(at now: Date = Date()) -> Bool {
        guard let unlockUntil else { return false }
        return unlockUntil > now
    }

    var isBreakingGlass: Bool { breakGlassEndsAt != nil }
}

enum RequestStatus: String, Codable { case pending, approved, denied, cancelled, expired }

enum RequestDecision: String, Codable {
    case approvedTimed = "approved_timed"
    case approvedEnd = "approved_end"
    case denied
}

enum RequestKind: String, Codable {
    /// Asking for time out of the block.
    case time
    /// Asking to open up apps that are blocked.
    case apps
}

/// What an app change asks for. Counts only: Apple keeps the apps themselves
/// private on the locked person's phone.
struct AppChange: Codable, Equatable {
    let mode: String?
    let openedApps: Int?
    let openedCategories: Int?
    let appCount: Int?
    let categoryCount: Int?
    let allowedCount: Int?

    /// "keep 2 more apps open", "unblock 1 app and 1 category".
    var request: String {
        let apps = openedApps ?? 0, categories = openedCategories ?? 0
        if mode == BlockMode.allExcept.rawValue {
            let parts = [
                apps > 0 ? "\(apps) more \(apps == 1 ? "app" : "apps")" : nil,
                categories > 0 ? "\(categories) more \(categories == 1 ? "category" : "categories")" : nil,
            ].compactMap { $0 }
            return "keep \(parts.joined(separator: " and ")) open"
        }
        return "unblock \(AppChange.describe(apps: apps, categories: categories))"
    }

    /// "2 apps and 1 category".
    static func describe(apps: Int, categories: Int) -> String {
        [
            apps > 0 ? "\(apps) \(apps == 1 ? "app" : "apps")" : nil,
            categories > 0 ? "\(categories) \(categories == 1 ? "category" : "categories")" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
    }
}

struct UnlockRequest: Codable, Identifiable, Equatable {
    let id: UUID
    let blockId: UUID
    let requesterId: UUID
    let holderId: UUID
    let requestedMinutes: Int?
    let status: RequestStatus
    let decision: RequestDecision?
    let approvedMinutes: Int?
    let unlockUntil: Date?
    let createdAt: Date
    let decidedAt: Date?
    /// Optional so rows from before migration 0005 decode as time requests.
    let kind: RequestKind?
    let change: AppChange?

    var isAppChange: Bool { kind == .apps }
}

struct Keyholder: Codable, Equatable {
    let key: Key
    let profile: Profile
}

/// A locked person asking for a bigger daily allowance.
struct AllowanceRequest: Codable, Identifiable, Equatable {
    let id: UUID
    let blockId: UUID
    let requesterId: UUID
    let holderId: UUID
    let minutes: Int
    let status: RequestStatus
    let createdAt: Date
    let decidedAt: Date?
}

/// One person whose key I hold.
struct HeldKey: Codable, Identifiable, Equatable {
    let key: Key
    let profile: Profile
    let block: Block?
    let streak: StreakState?
    let pendingRequest: UnlockRequest?
    /// A pending request to open up apps, separate from any request for time.
    let pendingAppChange: UnlockRequest?
    /// A pending request for a bigger daily allowance.
    let pendingAllowance: AllowanceRequest?
    let requestsThisWeek: Int

    var id: UUID { key.id }
}

/// Everything the home screen needs. Produced by the `me_snapshot()` RPC.
struct Snapshot: Codable, Equatable {
    let serverTime: Date
    let me: Profile
    let streak: StreakState
    let block: Block?
    let keyholder: Keyholder?
    let myPendingRequest: UnlockRequest?
    /// My latest app change for the current block, whatever its status.
    let myAppChange: UnlockRequest?
    /// My pending request for a bigger daily allowance.
    let myAllowanceRequest: AllowanceRequest?
    let held: [HeldKey]
}

/// A week under one key, for the key detail page. From `key_history()`.
struct KeyHistory: Decodable, Equatable {
    let requests: Int
    let given: Int
    let unlockedMinutes: Int
    let requestsList: [UnlockRequest]
    let blocks: [HistoryBlock]
    let lastBlock: HistoryBlock?
}

struct HistoryBlock: Decodable, Equatable {
    let startedAt: Date
    let endedAt: Date?
    let endedReason: BlockEndReason?
    let mode: String?
    let allowedCount: Int?
    let appCount: Int?
    let categoryCount: Int?
}

struct Device: Codable {
    let id: UUID
    let deviceSecret: String
    let apnsToken: String?
}

enum InviteMode: String, Codable, CaseIterable, Identifiable {
    case holdMine = "hold_mine"
    case iHoldYours = "i_hold_yours"
    case mutual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdMine: return "Hold my key"
        case .iHoldYours: return "I'll hold your key"
        case .mutual: return "Mutual pact"
        }
    }

    var detail: String {
        switch self {
        case .holdMine: return "They can unlock you. They block nothing themselves."
        case .iHoldYours: return "You can unlock them. You block nothing yourself."
        case .mutual: return "You hold each other's keys."
        }
    }
}

struct InvitePreview: Codable {
    let code: String
    let mode: InviteMode
    let inviterId: UUID
    let inviterName: String
    let usable: Bool
}

/// Durations offered when asking for or granting time.
enum UnlockDuration: Hashable, Identifiable {
    case minutes(Int)
    case restOfDay
    /// Any length the person dials in, from 15 minutes to 24 hours.
    case custom(Int)

    static let minimumMinutes = 15
    static let maximumMinutes = 1440

    var id: String {
        switch self {
        case .minutes(let m): return "m\(m)"
        case .restOfDay: return "rest"
        case .custom(let m): return "c\(m)"
        }
    }

    static let presets: [UnlockDuration] = [.minutes(15), .minutes(30), .minutes(60), .restOfDay]

    var label: String {
        switch self {
        case .minutes(let m): return m >= 60 ? "\(m / 60) hour" : "\(m) min"
        case .restOfDay: return "Rest of today"
        case .custom(let m): return Self.format(minutes: m)
        }
    }

    /// "45 min", "2 h", "1 h 20 min".
    static func format(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) min"
    }

    /// Minutes to send to the server, always within 15 minutes to 24 hours.
    func minutes(now: Date = Date()) -> Int {
        switch self {
        case .minutes(let m):
            return m
        case .custom(let m):
            return min(Self.maximumMinutes, max(Self.minimumMinutes, m))
        case .restOfDay:
            let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
            let m = Int(midnight.timeIntervalSince(now) / 60)
            return min(Self.maximumMinutes, max(Self.minimumMinutes, m))
        }
    }
}
