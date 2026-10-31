import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

/// Runs without the app. Restores shields when an approved unlock expires,
/// lifts everything when Break Glass completes, and posts heartbeats.
final class MonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        SharedStore.note("intervalDidStart \(activity.rawValue)")
        if activity == .heartbeat {
            postHeartbeat()
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        SharedStore.note("intervalDidEnd \(activity.rawValue)")

        switch activity {
        case .unlockWindow:
            SharedStore.unlockUntil = nil
            SharedStore.pendingShieldRequestAt = nil
            if SharedStore.blockActive {
                ShieldController.applyStoredShields()
            }
            postHeartbeat()

        case .breakGlass:
            ShieldController.clearEverything()
            SharedStore.clearBlockState()
            DeviceAPI.post(.breakGlassDone)

        case .heartbeat:
            postHeartbeat()

        default:
            break
        }
    }

    private func postHeartbeat() {
        let authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        DeviceAPI.post(.heartbeat, payload: [
            "authorized": authorized,
            "shielded": ShieldController.isShielding,
        ])
    }
}
