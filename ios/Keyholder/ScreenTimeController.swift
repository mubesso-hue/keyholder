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

    func persistSelection() {
        SharedStore.selection = selection
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
            if let selection = SharedStore.selection {
                ShieldController.applyShields(selection)
            }
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
