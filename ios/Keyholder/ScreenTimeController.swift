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
            MonitorScheduler.cancel(.unlockWindow, .breakGlass)
            SharedStore.clearBlockState()
            return
        }

        SharedStore.blockID = block.id.uuidString
        SharedStore.blockActive = true

        if let until = block.unlockUntil, until > now {
            ShieldController.liftShieldsKeepingRemovalDenied()
            SharedStore.unlockUntil = until
            SharedStore.pendingShieldRequestAt = nil
            try? MonitorScheduler.schedule(.unlockWindow, until: until)
        } else {
            SharedStore.unlockUntil = nil
            ShieldController.applyStoredShields()
            MonitorScheduler.cancel(.unlockWindow)
        }

        if let endsAt = block.breakGlassEndsAt {
            SharedStore.breakGlassEndsAt = endsAt
            try? MonitorScheduler.schedule(.breakGlass, until: endsAt)
        } else {
            SharedStore.breakGlassEndsAt = nil
            MonitorScheduler.cancel(.breakGlass)
        }

        MonitorScheduler.ensureDailyHeartbeat()
    }
}
