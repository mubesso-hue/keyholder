import Foundation

// Decoded with .convertFromSnakeCase and SupabaseDates.decode (see SupabaseService).

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
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

    var isActive: Bool { status == .active }

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
}

struct Keyholder: Codable, Equatable {
    let key: Key
    let profile: Profile
}

/// One person whose key I hold.
struct HeldKey: Codable, Identifiable, Equatable {
    let key: Key
    let profile: Profile
    let block: Block?
    let streak: StreakState?
    let pendingRequest: UnlockRequest?
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
    let held: [HeldKey]
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

    var id: String {
        switch self {
        case .minutes(let m): return "m\(m)"
        case .restOfDay: return "rest"
        }
    }

    static let presets: [UnlockDuration] = [.minutes(15), .minutes(30), .minutes(60), .restOfDay]

    var label: String {
        switch self {
        case .minutes(let m): return m >= 60 ? "\(m / 60) hour" : "\(m) min"
        case .restOfDay: return "Rest of today"
        }
    }

    /// Minutes to send to the server. Rest-of-day is clamped to the 15 min minimum.
    func minutes(now: Date = Date()) -> Int {
        switch self {
        case .minutes(let m):
            return m
        case .restOfDay:
            let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
            let m = Int(midnight.timeIntervalSince(now) / 60)
            return min(1440, max(15, m))
        }
    }
}
