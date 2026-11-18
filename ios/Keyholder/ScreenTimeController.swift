import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Owns Screen Time authorization, the chosen apps, and the job of making the
/// phone match the server's idea of the block.
@MainActor
final class ScreenTimeController: ObservableObject {
    @Published private(set) var status: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
    @Published var selection: FamilyActivitySelection = SharedStore.selection ?? FamilyActivitySelection()
    /// Apps that stay open in everything-except mode. Picking a category such as
    /// Finance keeps every app in it open, hence includeEntireCategory.
    @Published var allowedSelection: FamilyActivitySelection =
        SharedStore.allowedSelection ?? FamilyActivitySelection(includeEntireCategory: true)
    @Published var mode: BlockMode = SharedStore.blockMode
    /// Daily allowance chosen at Lock: minutes a day on `allowanceSelection`. 0 = none.
    @Published var allowanceMinutes: Int = UserDefaults.standard.integer(forKey: "lastAllowanceMinutes")
    @Published var allowanceSelection: FamilyActivitySelection =
        SharedStore.allowanceSelection ?? FamilyActivitySelection(includeEntireCategory: true)
    @Published private(set) var lastError: String?

    var isAuthorized: Bool { status == .approved }

    var selectionCounts: (apps: Int, categories: Int) {
        (selection.applicationTokens.count, selection.categoryTokens.count)
    }

    func refreshStatus() {
        status = AuthorizationCenter.shared.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            lastError = error.localizedDescription
        }
        refreshStatus()
    }

    /// Number of apps kept open in everything-except mode.
    var allowedCount: Int { allowedSelection.applicationTokens.count }

    /// Replaces the selection for a mode while locked, without touching the mode.
    func setSelection(_ newValue: FamilyActivitySelection, for mode: BlockMode) {
        switch mode {
        case .selected:
            selection = newValue
            SharedStore.selection = newValue
        case .allExcept:
            allowedSelection = newValue
            SharedStore.allowedSelection = newValue
        }
    }

    func persistSelection() {
        SharedStore.selection = selection
        SharedStore.allowedSelection = allowedSelection
        SharedStore.blockMode = mode
    }

    /// Make the device match the server. Safe to call often.
    func reconcile(block: Block?, holderName: String?, now: Date = Date()) {
        SharedStore.holderName = holderName

        guard let block, block.isActive else {
            ShieldController.clearEverything()
            MonitorScheduler.cancel(.unlockWindow, .breakGlass, .allowance, .allowanceToday, .credit)
            SharedStore.clearBlockState()
            return
        }

        SharedStore.blockID = block.id.uuidString
        SharedStore.blockActive = true
        SharedStore.creditSeconds = block.credit
        syncCredit(block)
        // Given time on picked apps: open while Screen Time counts it. If it
        // can't count, the apps stay blocked rather than open uncounted.
        let counting = MonitorScheduler.ensureCreditCounting()

        if let until = block.unlockUntil, until > now {
            ShieldController.liftShieldsKeepingRemovalDenied()
            SharedStore.unlockUntil = until
            SharedStore.pendingShieldRequestAt = nil
            try? MonitorScheduler.schedule(.unlockWindow, until: until)
        } else {
            SharedStore.unlockUntil = nil
            MonitorScheduler.cancel(.unlockWindow)
            if counting {
                ShieldController.liftShieldsKeepingRemovalDenied()
                SharedStore.pendingShieldRequestAt = nil
            } else {
                ShieldController.applyStoredShields()
            }
        }

        if let endsAt = block.breakGlassEndsAt {
            SharedStore.breakGlassEndsAt = endsAt
            try? MonitorScheduler.schedule(.breakGlass, until: endsAt)
        } else {
            SharedStore.breakGlassEndsAt = nil
            MonitorScheduler.cancel(.breakGlass)
        }

        MonitorScheduler.ensureDailyHeartbeat()
        MonitorScheduler.ensureAllowance()
    }

    /// Takes the server's figures for given time. Used time only grows, so
    /// minutes counted here and not yet reported are kept.
    private func syncCredit(_ block: Block) {
        if SharedStore.creditBlockID != block.id.uuidString {
            MonitorScheduler.stopCreditCounting()
            SharedStore.creditBlockID = block.id.uuidString
            SharedStore.creditUsedSeconds = 0
            SharedStore.creditReportedSeconds = 0
        }
        let used = block.usedCredit
        SharedStore.noteCreditUsed(used)
        SharedStore.creditReportedSeconds = max(SharedStore.creditReportedSeconds, used)
        SharedStore.creditTotalSeconds = block.isAllExcept ? 0 : used + block.credit
    }

    /// Used seconds counted on this phone that the server hasn't heard yet.
    func unreportedCreditUse(for block: Block) -> Int? {
        guard block.isActive, !block.isAllExcept, SharedStore.creditBlockID == block.id.uuidString else { return nil }
        let used = SharedStore.creditUsedSeconds
        return used > max(SharedStore.creditReportedSeconds, block.usedCredit) ? used : nil
    }
}
