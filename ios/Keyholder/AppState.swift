import Foundation
import SwiftUI
import Supabase

/// Single source of truth for the UI. Talks to SupabaseService, keeps the
/// device reconciled through ScreenTimeController.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable { case loading, signedOut, signedIn }

    enum Sheet: Identifiable {
        case lock, request, breakGlass, invite, settings
        case accept(code: String?)
        case decide(HeldKey)

        var id: String {
            switch self {
            case .lock: return "lock"
            case .request: return "request"
            case .breakGlass: return "breakGlass"
            case .invite: return "invite"
            case .settings: return "settings"
            case .accept: return "accept"
            case .decide(let held): return "decide-\(held.id)"
            }
        }
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var sheet: Sheet?
    @Published var busy = false

    /// serverTime - localTime at last snapshot. Streak display uses server time.
    @Published private(set) var clockOffset: TimeInterval = 0

    /// Keyholder-only users skip the Screen Time prompt. Persisted so it stays skipped.
    @Published var skippedPermission: Bool = UserDefaults.standard.bool(forKey: "skippedPermission") {
        didSet { UserDefaults.standard.set(skippedPermission, forKey: "skippedPermission") }
    }

    let screenTime = ScreenTimeController()
    private let api = SupabaseService.shared
    private var channel: RealtimeChannelV2?
    private var unlockTimer: Task<Void, Never>?
    private var pendingAppleName: String?

    var serverNow: Date { Date().addingTimeInterval(clockOffset) }

    // MARK: Lifecycle

    func bootstrap() async {
        screenTime.refreshStatus()
        for await (event, session) in api.client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed:
                if session != nil {
                    if phase != .signedIn {
                        phase = .signedIn
                        await onSignedIn()
                    }
                } else {
                    phase = .signedOut
                }
            case .signedOut, .userDeleted:
                phase = .signedOut
                snapshot = nil
                channel = nil
            default:
                break
            }
        }
    }

    private func onSignedIn() async {
        if let name = pendingAppleName {
            pendingAppleName = nil
            _ = try? await api.updateDisplayName(name)
        }
        await refresh()
        await registerDevice(apnsToken: nil)
        channel = await api.subscribeToChanges { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        await PushRegistrar.requestPermissionAndRegister()
    }

    func signIn(idToken: String, nonce: String, fullName: String?) async {
        pendingAppleName = fullName
        await run { try await self.api.signInWithApple(idToken: idToken, nonce: nonce) }
    }

    func signOut() async {
        guard snapshot?.block?.isActive != true else {
            errorMessage = "You cannot sign out while locked. Ask your keyholder to end the block first."
            return
        }
        await run { try await self.api.signOut() }
    }

    // MARK: Refresh and reconcile

    func refresh() async {
        guard phase == .signedIn else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snap = try await api.snapshot()
            snapshot = snap
            clockOffset = snap.serverTime.timeIntervalSinceNow
            screenTime.reconcile(block: snap.block, holderName: snap.keyholder?.profile.displayName, now: serverNow)
            scheduleLocalTimers(for: snap.block)
            await checkAuthorizationAndHeartbeat(block: snap.block)
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// While the app is alive, refresh exactly when an unlock window or Break Glass ends.
    private func scheduleLocalTimers(for block: Block?) {
        unlockTimer?.cancel()
        unlockTimer = nil
        guard let block, block.isActive else { return }
        let candidates = [block.unlockUntil, block.breakGlassEndsAt].compactMap { $0 }.filter { $0 > serverNow }
        guard let next = candidates.min() else { return }
        let delay = next.timeIntervalSince(serverNow) + 1
        unlockTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.onLocalTimerFired()
        }
    }

    private func onLocalTimerFired() async {
        if let endsAt = snapshot?.block?.breakGlassEndsAt, endsAt <= serverNow {
            _ = try? await api.completeBreakGlass()
        }
        await refresh()
    }

    /// Detect a revoked Screen Time authorization and tell the server; otherwise heartbeat.
    ///
    /// iOS can briefly report "not authorized" when it isn't, for example right
    /// after access is granted during setup. A single reading once ended a fresh
    /// block, reset the streak and told the keyholder access was switched off.
    /// So: re-check several times over about five seconds, never act during the
    /// first minute of a block, and only then report a revocation.
    func checkAuthorizationAndHeartbeat(block: Block?) async {
        screenTime.refreshStatus()
        guard let block, block.isActive else { return }
        if screenTime.isAuthorized {
            try? await api.heartbeat(authorized: true, shielded: ShieldController.isShielding)
            return
        }
        guard !revocationCheckInFlight else { return }
        revocationCheckInFlight = true
        defer { revocationCheckInFlight = false }

        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            screenTime.refreshStatus()
            if screenTime.isAuthorized {
                try? await api.heartbeat(authorized: true, shielded: ShieldController.isShielding)
                return
            }
        }
        guard serverNow.timeIntervalSince(block.startedAt) > 60 else { return }
        try? await api.reportRevocation()
        await refreshSilently()
    }

    private var revocationCheckInFlight = false

    private func refreshSilently() async {
        if let snap = try? await api.snapshot() {
            snapshot = snap
            clockOffset = snap.serverTime.timeIntervalSinceNow
            screenTime.reconcile(block: snap.block, holderName: snap.keyholder?.profile.displayName, now: serverNow)
        }
    }

    func onForeground() async {
        guard phase == .signedIn else { return }
        await refresh()
    }

    // MARK: Device

    func registerDevice(apnsToken: String?) async {
        guard phase == .signedIn else { return }
        do {
            let device = try await api.registerDevice(apnsToken: apnsToken, deviceID: SharedStore.deviceID)
            SharedStore.deviceID = device.id.uuidString
            SharedStore.deviceSecret = device.deviceSecret
        } catch {
            errorMessage = error.userMessage
        }
    }

    // MARK: Actions

    func lock(coolingOffHours: Int) async {
        let mode = screenTime.mode
        let counts = screenTime.selectionCounts
        let allowedCount = screenTime.allowedCount
        if mode == .selected && counts.apps + counts.categories == 0 {
            errorMessage = "Pick at least one app or category."
            return
        }
        screenTime.persistSelection()
        await run {
            _ = try await self.api.startBlock(coolingOffHours: coolingOffHours, mode: mode,
                                              appCount: counts.apps, categoryCount: counts.categories,
                                              allowedCount: allowedCount)
        }
    }

    func requestUnlock(_ duration: UnlockDuration) async {
        await run { _ = try await self.api.requestUnlock(minutes: duration.minutes(now: self.serverNow)) }
    }

    func decide(_ request: UnlockRequest, decision: RequestDecision, duration: UnlockDuration? = nil) async {
        let minutes = duration?.minutes(now: serverNow)
        await run { _ = try await self.api.decideUnlock(requestID: request.id, decision: decision, minutes: minutes) }
    }

    func decide(requestID: UUID, decision: RequestDecision, minutes: Int?) async {
        await run { _ = try await self.api.decideUnlock(requestID: requestID, decision: decision, minutes: minutes) }
    }

    /// Keyholder acts without a request (e.g. to cut a Break Glass wait short).
    func holderUnlock(_ held: HeldKey, decision: RequestDecision, duration: UnlockDuration? = nil) async {
        let minutes = duration?.minutes(now: serverNow)
        await run { _ = try await self.api.holderUnlock(lockedID: held.profile.id, decision: decision, minutes: minutes) }
    }

    func startBreakGlass() async {
        await run { _ = try await self.api.startBreakGlass() }
    }

    func cancelBreakGlass() async {
        await run { _ = try await self.api.cancelBreakGlass() }
    }

    func lengthenCoolingOff(hours: Int) async {
        await run { _ = try await self.api.lengthenCoolingOff(hours: hours) }
    }

    func createInvite(mode: InviteMode) async -> String? {
        busy = true
        defer { busy = false }
        do {
            return try await api.createInvite(mode: mode)
        } catch {
            errorMessage = error.userMessage
            return nil
        }
    }

    func previewInvite(code: String) async -> InvitePreview? {
        do {
            return try await api.getInvite(code: code)
        } catch {
            errorMessage = error.userMessage
            return nil
        }
    }

    func acceptInvite(code: String) async -> Bool {
        var ok = false
        await run {
            try await self.api.acceptInvite(code: code)
            ok = true
        }
        return ok
    }

    func endKey(_ key: Key) async {
        await run { try await self.api.endKey(id: key.id) }
    }

    func updateDisplayName(_ name: String) async {
        await run { _ = try await self.api.updateDisplayName(name) }
    }

    // MARK: Deep links and notifications

    func handle(url: URL) {
        // keyholder://invite/CODE
        guard url.scheme == "keyholder", url.host == "invite" else { return }
        let code = url.pathComponents.dropFirst().first
        sheet = .accept(code: code)
    }

    func handleNotification(userInfo: [AnyHashable: Any], actionIdentifier: String) async {
        let data = userInfo["data"] as? [String: Any]
        let requestID = (data?["request_id"] as? String).flatMap(UUID.init(uuidString:))

        switch actionIdentifier {
        case PushRegistrar.Action.approve15:
            if let requestID { await decide(requestID: requestID, decision: .approvedTimed, minutes: 15) }
        case PushRegistrar.Action.approve60:
            if let requestID { await decide(requestID: requestID, decision: .approvedTimed, minutes: 60) }
        case PushRegistrar.Action.deny:
            if let requestID { await decide(requestID: requestID, decision: .denied, minutes: nil) }
        default:
            await refresh()
            // Tapping a request notification opens the decide sheet.
            if userInfo["category"] as? String == "UNLOCK_REQUEST",
               let held = snapshot?.held.first(where: { $0.pendingRequest?.id == requestID }) {
                sheet = .decide(held)
            }
        }
    }

    // MARK: Helpers

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            await refresh()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
