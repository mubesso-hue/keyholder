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
        if activity == .allowance {
            // A new day: the allowance apps open again.
            SharedStore.allowanceExhaustedDay = nil
            SharedStore.setAllowanceUsed(0)
            reapplyShieldsIfLocked()
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard activity == .allowance else { return }
        if event == .allowanceDone {
            SharedStore.note("allowance used up")
            SharedStore.allowanceExhaustedDay = SharedStore.today
            SharedStore.setAllowanceUsed(SharedStore.allowanceMinutes)
            reapplyShieldsIfLocked()
        } else if let minutes = event.allowanceUsedMinutes {
            SharedStore.setAllowanceUsed(max(SharedStore.allowanceUsedToday, minutes))
        }
    }

    /// Shields follow the allowance, except during time the keyholder gave.
    private func reapplyShieldsIfLocked() {
        guard SharedStore.blockActive else { return }
        if let until = SharedStore.unlockUntil, until > Date() { return }
        ShieldController.applyStoredShields()
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

    /// A liveness ping. It deliberately says nothing about Screen Time access:
    /// in the background the extension can read "not authorized" while access
    /// is fine, which once ended a block at midnight. Only the app, after
    /// repeated checks, reports a revocation.
    private func postHeartbeat() {
        DeviceAPI.post(.heartbeat, payload: [
            "shielded": ShieldController.isShielding,
        ])
    }
}
